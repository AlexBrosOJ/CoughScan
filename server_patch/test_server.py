"""Integration checks with REAL WAV decoding/features/SQLite/HTTP, fake ML weights.
Run in the server's environment: python -m unittest -v test_server.py
TensorFlow modules are stubbed before importing main; no TFHub network downloads.
"""
import ast
import importlib.util
import io
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import types
import unittest
import wave
import zipfile

import numpy as np
from fastapi.testclient import TestClient

# Stub only TensorFlow and weights; librosa/scipy/soundfile and HTTP remain real.
class Tensor(np.ndarray):
    def numpy(self):
        return np.asarray(self)


def tensor(value, **kwargs):
    return np.asarray(value, dtype=kwargs.get('dtype')).view(Tensor)


fake_tf = types.ModuleType('tensorflow')
fake_tf.float32 = np.float32
fake_tf.convert_to_tensor = tensor
fake_tf.reduce_mean = lambda value, axis: tensor(np.mean(value, axis=axis))
fake_tf.reduce_max = lambda value, axis: tensor(np.max(value, axis=axis))
sys.modules['tensorflow'] = fake_tf
sys.modules['tensorflow_hub'] = types.ModuleType('tensorflow_hub')


class Model:
    input_shape = (None, 2079)
    output_shape = (None, 1)
    def __init__(self):
        self.score = 0.8
        self.calls = 0
    def predict(self, features, verbose=0):
        assert features.shape == (1, 2079)
        self.calls += 1
        return np.array([[self.score]], dtype=np.float32)


class Scaler:
    n_features_in_ = 2079
    def transform(self, value):
        return value


class Yamnet:
    def __call__(self, waveform):
        assert len(waveform) == 16000
        return None, tensor(np.ones((2, 1024), dtype=np.float32)), None


def wav_bytes(amplitude=0.002, frames=48000, rate=48000):
    samples = amplitude * np.sin(2*np.pi*700*np.arange(frames)/rate)
    output = io.BytesIO()
    with wave.open(output, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes((samples*32767).astype('<i2').tobytes())
    return output.getvalue()


class ServerChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        os.environ['AUDIO_STORAGE_PATH'] = str(cls.root/'audio')
        os.environ['DB_PATH'] = str(cls.root/'test.db')
        for key in ['COUGH_THRESHOLD', 'MIN_RMS', 'MIN_PEAK', 'ENABLE_LEGACY_ENHANCEMENT']:
            os.environ.pop(key, None)
        spec = importlib.util.spec_from_file_location('patched_server_test', Path(__file__).with_name('main.py'))
        cls.server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.server)
        # Do not enter TestClient context: startup must not download/load real weights.
        cls.client = TestClient(cls.server.app)

    @classmethod
    def tearDownClass(cls):
        cls.client.close()
        cls.directory.cleanup()

    def setUp(self):
        s = self.server
        s.init_db()
        with sqlite3.connect(s.DB_PATH) as conn:
            conn.execute('DELETE FROM cough_records')
        for path in Path(s.AUDIO_STORAGE_PATH).glob('*'):
            path.unlink()
        s.OUR_MODEL = Model()
        s.SCALER = Scaler()
        s.YAMNET_MODEL = Yamnet()
        s.MIN_RMS = 0
        s.MIN_PEAK = 0
        s.THRESHOLD = 0.5
        s.ENABLE_LEGACY_ENHANCEMENT = False
        s.MAX_AUDIO_FILES = 500
        s._last_cleanup = 0

    def upload(self, data=None, name='chunk.wav'):
        return self.client.post('/upload', data={'device_id':'test_iPhone'},
            files={'audio': (name, wav_bytes() if data is None else data, 'audio/wav')})

    def count(self):
        with sqlite3.connect(self.server.DB_PATH) as conn:
            return conn.execute('SELECT COUNT(*) FROM cough_records').fetchone()[0]

    def test_quiet_audio_detected_without_old_gate_or_penalty(self):
        response = self.upload()
        self.assertEqual(response.status_code, 200, response.text)
        result = response.json()
        self.assertLess(result['rms'], 0.02)
        self.assertTrue(result['cough_detected'])
        self.assertAlmostEqual(result['probability'], 0.8, places=5)
        self.assertEqual(result['probability'], result['original_probability'])
        self.assertFalse(result['enhancement_applied'])
        self.assertTrue(result['audio_saved'])
        self.assertEqual(self.count(), 1)
        for field in ['status','message','cough_count','confidence','record_id','download_url','all_coughs_url']:
            self.assertIn(field, result)

    def test_negative_result_is_successful_and_saved(self):
        self.server.OUR_MODEL.score = 0.1
        result = self.upload().json()
        self.assertFalse(result['cough_detected'])
        self.assertEqual(result['cough_count'], 0)
        self.assertTrue(result['audio_saved'])

    def test_exact_silence_no_inference(self):
        result = self.upload(wav_bytes(0)).json()
        self.assertFalse(result['cough_detected'])
        self.assertTrue(result['skipped_by_gate'])
        self.assertEqual(self.server.OUR_MODEL.calls, 0)

    def test_corrupt_empty_oversize_audio_do_not_create_negative_records(self):
        self.assertEqual(self.upload(b'not a wav').status_code, 422)
        self.assertEqual(self.upload(b'').status_code, 400)
        before = self.server.MAX_UPLOAD_BYTES
        self.server.MAX_UPLOAD_BYTES = 10
        try:
            self.assertEqual(self.upload(b'x'*11).status_code, 413)
        finally:
            self.server.MAX_UPLOAD_BYTES = before
        self.assertEqual(self.count(), 0)

    def test_unloaded_or_broken_model_is_an_error(self):
        self.server.YAMNET_MODEL = None
        response = self.upload()
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()['status'], 'error')
        self.server.YAMNET_MODEL = Yamnet()
        self.server.OUR_MODEL.score = np.nan
        response = self.upload()
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json()['status'], 'error')
        self.assertEqual(self.count(), 0)

    def test_retry_is_idempotent_but_changed_content_is_not(self):
        data = wav_bytes()
        first = self.upload(data).json()
        second = self.upload(data).json()
        self.assertEqual(first['record_id'], second['record_id'])
        self.assertTrue(second['duplicate'])
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.server.OUR_MODEL.calls, 1)
        self.upload(wav_bytes(0.003))
        self.assertEqual(self.count(), 2)

    def test_download_zip_stats_and_existing_routes(self):
        result = self.upload().json()
        self.assertEqual(self.client.get(result['download_url']).content, wav_bytes())
        response = self.client.get('/coughs/audio/all')
        self.assertEqual(response.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
            self.assertEqual(len(archive.namelist()), 1)
            self.assertEqual(archive.read(archive.namelist()[0]), wav_bytes())
        for route in ['/','/health','/coughs/audio/list','/coughs/audio/stats',
                      '/stats/test_iPhone','/debug/stats/test_iPhone','/records/all',
                      '/records/test_iPhone/count','/records/export/test_iPhone',
                      '/records/export/test_iPhone?format=csv']:
            self.assertEqual(self.client.get(route).status_code, 200, route)
        health = self.client.get('/health').json()
        self.assertEqual(health['threshold'], 0.5)
        self.assertFalse(health['legacy_enhancement_enabled'])

    def test_gate_can_be_restored_by_configuration(self):
        self.server.MIN_RMS = 0.02
        result = self.upload().json()
        self.assertTrue(result['skipped_by_gate'])
        self.assertFalse(result['cough_detected'])

    def test_legacy_penalties_are_opt_in(self):
        self.server.ENABLE_LEGACY_ENHANCEMENT = True
        result = self.upload().json()
        self.assertTrue(result['enhancement_applied'])
        self.assertNotAlmostEqual(result['probability'], 0.8, places=4)

    def test_limit_includes_orphans_and_preserves_db_rows(self):
        root = Path(self.server.AUDIO_STORAGE_PATH)
        for i in range(4):
            (root/f'cough_orphan_{i}.wav').write_bytes(wav_bytes())
        self.server.MAX_AUDIO_FILES = 2
        self.upload()
        self.assertEqual(len(list(root.glob('cough_*.wav'))), 2)
        self.assertEqual(self.count(), 1)

    def test_retention_and_manual_age(self):
        self.upload()
        self.assertEqual(self.client.delete('/coughs/audio/cleanup?days_old=0').status_code, 422)
        self.assertEqual(self.client.delete('/coughs/audio/cleanup?days_old=1').status_code, 200)
        with sqlite3.connect(self.server.DB_PATH) as conn:
            conn.execute("UPDATE cough_records SET timestamp='2000-01-01 00:00:00'")
        self.assertEqual(self.client.delete('/records/cleanup').status_code, 200)
        self.assertEqual(self.count(), 0)
        self.assertEqual(len(list(Path(self.server.AUDIO_STORAGE_PATH).glob('cough_*.wav'))), 0)

    def test_save_failure_does_not_create_success_or_negative_record(self):
        before = self.server.save_cough_audio
        self.server.save_cough_audio = lambda *args: ''
        try:
            response = self.upload()
            self.assertEqual(response.status_code, 500)
            self.assertEqual(response.json()['status'], 'error')
            self.assertEqual(self.count(), 0)
        finally:
            self.server.save_cough_audio = before

    def test_concurrent_retries_create_one_record(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as executor:
            responses = list(executor.map(lambda _: self.upload(), range(2)))
        self.assertEqual([r.status_code for r in responses], [200, 200])
        self.assertEqual(responses[0].json()['record_id'], responses[1].json()['record_id'])
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.server.OUR_MODEL.calls, 1)

    def test_feature_vector_matches_original(self):
        original_source = Path(__file__).with_name('main.original.py').read_text()
        node = next(n for n in ast.parse(original_source).body
                    if isinstance(n, ast.FunctionDef) and n.name == 'extract_features_new')
        namespace = dict(vars(self.server))
        exec(compile(ast.Module(body=[node], type_ignores=[]), '<original-features>', 'exec'), namespace)
        waveform = np.sin(2*np.pi*600*np.arange(16000)/16000).astype(np.float32)
        before = namespace['extract_features_new'](waveform, 16000, self.server.YAMNET_MODEL)
        after = self.server.extract_features_new(waveform, 16000, self.server.YAMNET_MODEL)
        np.testing.assert_allclose(before, after, rtol=0, atol=0)
        self.assertEqual(after.shape, (2079,))

    def test_threshold_boundary_is_preserved(self):
        self.server.OUR_MODEL.score = 0.5
        result = self.upload().json()
        self.assertFalse(result['cough_detected'])  # Same strict > comparison as original.

    def test_all_original_api_routes_preserved(self):
        expected = {'/upload','/download/{record_id}','/coughs/audio/list','/coughs/audio/all',
            '/coughs/audio/stats','/coughs/audio/cleanup','/stats/{device_id}',
            '/debug/stats/{device_id}','/records/all','/records/{device_id}/count',
            '/records/cleanup','/records/export/{device_id}','/health','/'}
        actual = {route.path for route in self.server.app.routes}
        self.assertTrue(expected <= actual)


if __name__ == '__main__':
    unittest.main(verbosity=2)
