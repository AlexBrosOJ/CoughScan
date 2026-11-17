# ONE cell in your existing Colab AFTER the real model, scaler and WAV have loaded.
# Upload the NEW server_patch/main.py when prompted. Only inference functions run.
import ast
import logging
import tempfile
import threading
import hashlib
import os
from pathlib import Path
import numpy as np
import pandas as pd
from google.colab import files

assert OUR_MODEL is not None and SCALER is not None and YAMNET_MODEL is not None, 'Сначала загрузите настоящую модель/scaler/YAMNet'
uploaded_patch = files.upload()
assert len(uploaded_patch) == 1, 'Выберите только новый main.py'
patch_source = next(iter(uploaded_patch.values())).decode('utf-8')
patch_tree = ast.parse(patch_source)
names = {'extract_features_new', 'fast_enhanced_check', 'analyze_audio'}
functions = [n for n in patch_tree.body if isinstance(n, ast.FunctionDef) and n.name in names]
assert {n.name for n in functions} == names

class DiagnosticHTTPError(Exception):
    def __init__(self, status_code, detail):
        super().__init__(f'{status_code}: {detail}')

namespace = dict(globals())
namespace.update(THRESHOLD=0.5, MIN_RMS=0.0, MIN_PEAK=0.0,
                 ENABLE_LEGACY_ENHANCEMENT=False, _MODEL_LOCK=threading.RLock(),
                 HTTPException=DiagnosticHTTPError, logger=logging.getLogger('patch_recheck'))
exec(compile(ast.Module(body=functions, type_ignores=[]), '<patch-inference>', 'exec'), namespace)
checked = []
for path in sorted(Path(AUDIO).glob('*.wav')):
    raw = path.read_bytes()
    row = dict(file=path.name, sha256=hashlib.sha256(raw).hexdigest())
    try:
        row.update(namespace['analyze_audio'](raw, path.name))
    except Exception as error:
        row['error'] = repr(error)
    checked.append(row)
recheck = pd.DataFrame(checked)
recheck.to_csv(Path(ROOT)/'patch_recheck.csv', index=False)
display(recheck)
# Prefer SHA256: filenames may differ after archive extraction.
if 'labels' in globals() and 'sha256' in labels and 'cough_detected' in recheck:
    tagged = recheck.merge(labels[['sha256','label']].drop_duplicates('sha256'), on='sha256')
    tagged['label'] = pd.to_numeric(tagged.label, errors='coerce')
    tagged = tagged[tagged.label.isin([0,1]) & tagged.cough_detected.notna()]
    tp = int(((tagged.label==1) & (tagged.cough_detected==True)).sum())
    fp = int(((tagged.label==0) & (tagged.cough_detected==True)).sum())
    print('Найдено кашлевых фрагментов:', tp, '/', int((tagged.label==1).sum()))
    print('Ложных срабатываний:', fp, '/', int((tagged.label==0).sum()))
files.download(str(Path(ROOT)/'patch_recheck.csv'))
print('Это проверка реальной модели в Colab. Для запуска сервера ещё нужны startup, /health и HTTP smoke test.')
