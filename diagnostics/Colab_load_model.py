# Paste into ONE Colab cell. Downloads only the user's public model artifacts.
from pathlib import Path
import hashlib
import requests
import tensorflow as tf
import joblib

ROOT = Path(globals().get('ROOT', '/content/cough_diagnostics'))
ROOT.mkdir(parents=True, exist_ok=True)
for name in ['cough_detection_final_optimized.keras', 'cough_scaler_final_optimized.pkl']:
    destination = ROOT / name
    if not destination.exists():
        url = 'https://raw.githubusercontent.com/AlexBrosOJ/Yam/main/' + name
        print('Скачиваю', name)
        temporary = destination.with_suffix(destination.suffix + '.part')
        with requests.get(url, stream=True, timeout=(20, 180)) as response:
            response.raise_for_status()
            with temporary.open('wb') as output:
                for block in response.iter_content(1024*1024):
                    output.write(block)
        with temporary.open('rb') as downloaded:
            if downloaded.read(100).startswith(b'version https://git-lfs.github.com'):
                raise ValueError('Git LFS pointer вместо модели. Нужен оригинальный файл с сервера.')
        temporary.replace(destination)
    print(name, destination.stat().st_size, 'байт; SHA256:', hashlib.sha256(destination.read_bytes()).hexdigest())
OUR_MODEL = tf.keras.models.load_model(ROOT / 'cough_detection_final_optimized.keras', compile=False)
SCALER = joblib.load(ROOT / 'cough_scaler_final_optimized.pkl')
assert OUR_MODEL.input_shape[-1] == 2079, f'Неожиданный вход модели: {OUR_MODEL.input_shape}'
assert getattr(SCALER, 'n_features_in_', None) == 2079, 'Scaler не для 2079 признаков'
print('Модель загружена:', OUR_MODEL.input_shape, '→', OUR_MODEL.output_shape)
print('Scaler загружен. Теперь ПОВТОРИТЕ ячейку с def diagnose(path) и анализом WAV (10/65...).')
print('Это версия из GitHub main: для точного совпадения с сервером сверьте SHA256 его артефактов.')
