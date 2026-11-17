# Paste this entire file into ONE new Colab code cell after the WAV/results cells.
from pathlib import Path
import html
import numpy as np
import pandas as pd
import librosa
import ipywidgets as widgets
from IPython.display import Audio, display, clear_output
from google.colab import files, output as colab_output

colab_output.enable_custom_widget_manager()
assert 'results' in globals() and 'AUDIO' in globals(), 'Сначала выполните загрузку WAV и анализ.'
ROOT = Path(ROOT)
LABEL_PATH = ROOT / 'labels.csv'
_audio_dir = Path(AUDIO)
_required = ['file'] + (['sha256'] if 'sha256' in results else [])
_labels = results[_required].drop_duplicates('file').copy()
_labels['label'] = np.nan
_labels['source'] = ''
_labels['reviewed'] = False
if LABEL_PATH.exists():
    _old = pd.read_csv(LABEL_PATH).fillna('')
    _old = _old.drop_duplicates('file', keep='last').set_index('file')
    for _i, _row in _labels.iterrows():
        if _row.file not in _old.index:
            continue
        _saved = _old.loc[_row.file]
        if 'sha256' in _saved and 'sha256' in _row and _saved.sha256 != _row.sha256:
            continue
        _value = pd.to_numeric(_saved.get('label', ''), errors='coerce')
        _labels.at[_i, 'label'] = _value if _value in (0, 1) else np.nan
        _labels.at[_i, 'source'] = _saved.get('source', '')
        _labels.at[_i, 'reviewed'] = (str(_saved.get('reviewed', '')).lower() == 'true' or _value in (0, 1))
_labels = _labels.reset_index(drop=True)
assert len(_labels), 'Нет файлов для прослушивания.'
_pending = _labels.index[~_labels.reviewed].tolist()
_position = _pending[0] if _pending else 0
_panel = widgets.Output()
_header = widgets.HTML()
_status = widgets.HTML()
_source = widgets.Dropdown(options=[('Источник неизвестен', ''), ('Живой кашель / микрофон', 'live'),
                                    ('Звук из видео / динамика', 'video'), ('Обычный фон', 'background')],
                           description='Источник:', style={'description_width':'initial'})
_louder = widgets.Checkbox(value=False, description='Усилить только для прослушивания')
_yes = widgets.Button(description='Да, кашель', button_style='success')
_no = widgets.Button(description='Нет кашля', button_style='danger')
_unsure = widgets.Button(description='Не уверен')
_back = widgets.Button(description='← Назад')
_next = widgets.Button(description='Вперёд →')
_export = widgets.Button(description='Скачать ответы CSV', button_style='info')


def _save_labels():
    temporary = LABEL_PATH.with_suffix('.tmp')
    _labels.to_csv(temporary, index=False)
    temporary.replace(LABEL_PATH)
    # Compatible with subsequent metrics cells; no upload dialog needed.
    globals()['labels'] = _labels.copy()


def _render_label():
    row = _labels.iloc[_position]
    done = int(_labels.reviewed.sum())
    value = 'Да' if row.label == 1 else 'Нет' if row.label == 0 else 'Не уверен' if row.reviewed else 'Ещё не отмечено'
    _header.value = (f'<b>Фрагмент {_position+1}/{len(_labels)} · проверено {done}/{len(_labels)}</b><br>'
                     f'{html.escape(row.file)}<br>Ответ: <b>{value}</b>')
    _source.value = row.source if row.source in ['', 'live', 'video', 'background'] else ''
    with _panel:
        clear_output(wait=True)
        try:
            y, sr = librosa.load(_audio_dir / row.file, sr=None, mono=True)
            # Label the exact interval seen by the server, even for longer uploaded files.
            y = y[:sr]
            print('Первая секунда записи. Оценки модели скрыты, чтобы не влиять на ответ.')
            if _louder.value:
                print('Включено усиление плеера. Исходный WAV и вход модели НЕ меняются.')
            display(Audio(y, rate=sr, normalize=_louder.value, autoplay=True))
            print('Если звук не включился автоматически, нажмите ▶ в плеере.')
        except Exception as error:
            print('Не удалось воспроизвести:', error, '— выберите «Не уверен».')
    _back.disabled = _position == 0
    _next.disabled = _position == len(_labels)-1


def _answer(value):
    global _position
    _labels.at[_position, 'label'] = value
    _labels.at[_position, 'source'] = _source.value
    _labels.at[_position, 'reviewed'] = True
    _save_labels()
    pending = _labels.index[~_labels.reviewed].tolist()
    later = [i for i in pending if i > _position]
    if later:
        _position = later[0]
    elif pending:
        _position = pending[0]
    else:
        _status.value = '<b>Готово! Все записи просмотрены. Нажмите «Скачать ответы CSV».</b>'
    _render_label()


def _move(offset):
    global _position
    _position = max(0, min(len(_labels)-1, _position+offset))
    _render_label()


def _download_answers(_):
    _save_labels()
    files.download(str(LABEL_PATH))

_yes.on_click(lambda _: _answer(1))
_no.on_click(lambda _: _answer(0))
_unsure.on_click(lambda _: _answer(np.nan))
_back.on_click(lambda _: _move(-1))
_next.on_click(lambda _: _move(1))
_export.on_click(_download_answers)
_louder.observe(lambda change: _render_label(), names='value')
display(widgets.VBox([_header, _source, _louder, _panel,
                      widgets.HBox([_yes, _no, _unsure]), widgets.HBox([_back, _next, _export]), _status]))
print('Ответ сохраняется после каждого нажатия в этой сессии Colab. Можно остановиться и продолжить.')
print('Перед закрытием/сбросом среды скачайте CSV: файлы среды Colab не постоянны.')
_render_label()
