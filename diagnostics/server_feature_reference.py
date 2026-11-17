# Extracted unchanged from the user-supplied server, for offline reproduction only.
def extract_features_new(waveform, sr, yamnet_model):
    """Извлекает РОВНО 2079 фич как в обученной модели"""
    try:
        if np.max(np.abs(waveform)) < 0.01:
            return None
        
        max_val = np.max(np.abs(waveform))
        waveform = waveform / (max_val + 1e-8)
        
        waveform_tf = tf.convert_to_tensor(waveform, dtype=tf.float32)
        _, embeddings, _ = yamnet_model(waveform_tf)
        
        avg_pool = tf.reduce_mean(embeddings, axis=0).numpy()
        max_pool = tf.reduce_max(embeddings, axis=0).numpy()
        
        mfcc = librosa.feature.mfcc(y=waveform, sr=sr, n_mfcc=13, hop_length=512)
        mfcc_mean = np.mean(mfcc, axis=1)
        mfcc_std = np.std(mfcc, axis=1)
        
        spectral_centroid = librosa.feature.spectral_centroid(y=waveform, sr=sr, hop_length=512)[0]
        spectral_bandwidth = librosa.feature.spectral_bandwidth(y=waveform, sr=sr, hop_length=512)[0]
        
        spectral_features = np.array([
            np.mean(spectral_centroid),
            np.std(spectral_centroid),  
            np.mean(spectral_bandwidth)
        ])
        
        zcr = librosa.feature.zero_crossing_rate(waveform, hop_length=512)[0]
        zcr_mean = np.mean(zcr)
        
        rms = librosa.feature.rms(y=waveform, hop_length=512)[0]
        rms_mean = np.mean(rms)
        
        combined = np.concatenate([
            avg_pool,
            max_pool,  
            mfcc_mean,
            mfcc_std,
            spectral_features,
            [zcr_mean, rms_mean]
        ])
        
        expected_dim = 2079
        if len(combined) != expected_dim:
            logger.warning(f"Размерность фич {len(combined)} вместо {expected_dim}")
            if len(combined) > expected_dim:
                combined = combined[:expected_dim]
            else:
                padding = np.zeros(expected_dim - len(combined))
                combined = np.concatenate([combined, padding])
        
        return combined
        
    except Exception as e:
        logger.error(f"Ошибка извлечения фич: {e}")
        return None

def fast_enhanced_check(waveform, sr, original_prob):
    """Быстрая улучшенная проверка (умеренные штрафы)"""
    
    modified_prob = original_prob
    
    # 1. Проверка соотношения низких/средних частот
    mfcc = librosa.feature.mfcc(y=waveform, sr=sr, n_mfcc=13, hop_length=512)
    low_freq = np.mean(np.abs(mfcc[:4, :]))      # Низкие
    mid_freq = np.mean(np.abs(mfcc[4:8, :]))     # Средние
    low_to_mid = low_freq / (mid_freq + 1e-6)
    
    # Умеренные штрафы: макс -20%
    if low_to_mid < 0.18:  # Слишком мало низких (ложное)
        modified_prob *= 0.78  # -10% (было -35%)
    elif low_to_mid > 0.27:  # Много низких (кашель)
        modified_prob *= 1.25  # +10% (было +20%)
    
    # 2. Проверка резкости атаки
    envelope = np.abs(waveform)
    envelope_smooth = np.convolve(envelope, np.ones(1000)/1000, mode='same')
    
    from scipy.signal import find_peaks
    peaks, properties = find_peaks(envelope_smooth, height=np.max(envelope_smooth)*0.3)
    
    if len(peaks) > 0:
        peak_to_rms_ratio = envelope_smooth[peaks[0]] / (np.sqrt(np.mean(waveform**2)) + 1e-6)
        
        # Умеренные штрафы
        if peak_to_rms_ratio < 7.1:  # Низкая пиковость (ложное)
            modified_prob *= 0.82  # -10% (было -20%)
        elif peak_to_rms_ratio > 7.3:  # Высокая пиковость (кашель)
            modified_prob *= 1.25  # +10% (было +15%)
    else:
        # Нет пиков - легкий штраф
        modified_prob *= 0.75  # -5% (было -30%)
    
    # 3. Проверка спектральной плоскости
    spectral_flatness = np.mean(librosa.feature.spectral_flatness(y=waveform))
    
    # Умеренные штрафы
    if spectral_flatness < 0.04:  # Слишком тонально (ложное)
        modified_prob *= 0.82  # -5% (было -15%)
    elif spectral_flatness > 0.05:  # Более шумно (кашель)
        modified_prob *= 1.152  # +5% (было +10%)
    
    # 4. Количество пиков
    zcr = librosa.feature.zero_crossing_rate(waveform, hop_length=256)[0]
    zcr_peaks = len(find_peaks(zcr, height=np.mean(zcr)*1.5)[0])
    
    # Умеренные штрафы
    if zcr_peaks < 35:  # Мало изменений (ложное)
        modified_prob *= 0.9  # -5% (было -25%)
    elif zcr_peaks > 45:  # Много изменений (кашель)
        modified_prob *= 1.1  # +5% (было +15%)
    
    # Возвращаем float, а не numpy тип!
    return float(np.clip(modified_prob, 0.0, 1.0))
