#!/usr/bin/env python3
"""
Validate LavaSR enhancement: run Python Vocos reference on a WAV file,
then compare against Swift output (if available).

Usage:
    cd /Users/system-backup/dev_local/pocket-tts-macos
    source /Users/system-backup/dev_local/pocket-tts/.venv/bin/activate
    python scripts/validate_lavasr_enhancement.py "/path/to/input.wav"
"""

import sys
from pathlib import Path

import numpy as np
import torch
import soundfile as sf
from huggingface_hub import hf_hub_download


def load_vocos_enhancer():
    """Load LavaSR v2 enhancer using Vocos directly."""
    from vocos import Vocos
    from vocos.feature_extractors import MelSpectrogramFeatures

    # Load weights
    model_path = hf_hub_download("YatharthS/LavaSR", "enhancer_v2/pytorch_model.bin")
    state_dict = torch.load(model_path, map_location="cpu", weights_only=True)

    # Build model from config (matching enhancer_v2/config.yaml)
    from vocos.models import VocosBackbone
    from vocos.heads import ISTFTHead

    feature_extractor = MelSpectrogramFeatures(
        sample_rate=44100,
        n_fft=2048,
        hop_length=512,
        n_mels=80,
        padding="same",
        f_min=0,
        f_max=8000,
        norm="slaney",
        mel_scale="slaney",
    )

    backbone = VocosBackbone(
        input_channels=80,
        dim=512,
        intermediate_dim=1536,
        num_layers=8,
    )

    head = ISTFTHead(
        dim=512,
        n_fft=2048,
        hop_length=512,
        padding="same",
    )

    # Load state dict into components
    feat_keys = {k: v for k, v in state_dict.items() if k.startswith("feature_extractor.")}
    backbone_keys = {k: v for k, v in state_dict.items() if k.startswith("backbone.")}
    head_keys = {k: v for k, v in state_dict.items() if k.startswith("head.")}

    feature_extractor.load_state_dict(feat_keys, strict=False)
    backbone.load_state_dict({k.removeprefix("backbone."): v for k, v in backbone_keys.items()})
    head.load_state_dict({k.removeprefix("head."): v for k, v in head_keys.items()}, strict=False)

    feature_extractor.eval()
    backbone.eval()
    head.eval()

    return feature_extractor, backbone, head


def rms_normalize(audio: np.ndarray, target_db: float = -16.0) -> np.ndarray:
    rms = np.sqrt(np.mean(audio ** 2))
    if rms < 1e-8:
        return audio
    target_rms = 10 ** (target_db / 20.0)
    gain = target_rms / rms
    return np.clip(audio * gain, -1.0, 1.0)


def enhance_python(input_path: str, output_path: str):
    """Run the full Python Vocos enhancement pipeline."""
    print(f"Loading: {input_path}")

    # Load audio at 44100 Hz mono (using soundfile to avoid torchcodec dep)
    audio_np, sr = sf.read(input_path, dtype="float32")
    if audio_np.ndim > 1:
        audio_np = audio_np.mean(axis=1)
    if sr != 44100:
        # Simple resample via interpolation
        ratio = 44100 / sr
        indices = np.arange(int(len(audio_np) * ratio)) / ratio
        audio_np = np.interp(indices, np.arange(len(audio_np)), audio_np).astype(np.float32)
        sr = 44100
    audio = torch.from_numpy(audio_np).unsqueeze(0)

    # Trim to 30 seconds max
    max_samples = 30 * sr
    audio = audio[:, :max_samples]
    print(f"Audio: {audio.shape[1]} samples @ {sr}Hz, range [{audio.min():.4f}, {audio.max():.4f}]")

    # Load model
    print("Loading LavaSR v2 enhancer...")
    feature_extractor, backbone, head = load_vocos_enhancer()

    # Run pipeline
    with torch.no_grad():
        # Step 1: Mel spectrogram
        mel = feature_extractor(audio)
        print(f"Mel shape: {mel.shape}, range [{mel.min():.4f}, {mel.max():.4f}]")

        # Step 2: Backbone
        features = backbone(mel)
        print(f"Features shape: {features.shape}, range [{features.min():.4f}, {features.max():.4f}]")

        # Step 3: ISTFT head
        enhanced = head(features)
        print(f"Enhanced shape: {enhanced.shape}, range [{enhanced.min():.4f}, {enhanced.max():.4f}]")

    # Convert to numpy
    enhanced_np = enhanced.squeeze().numpy()

    # RMS normalize to -16 dB
    normalized = rms_normalize(enhanced_np, target_db=-16.0)
    print(f"Normalized: {len(normalized)} samples, range [{normalized.min():.4f}, {normalized.max():.4f}]")

    # Save
    sf.write(output_path, normalized, 44100, subtype="FLOAT")
    print(f"Saved Python reference: {output_path}")

    return normalized


def compare_outputs(python_path: str, swift_path: str):
    """Compare Python and Swift outputs numerically."""
    py_audio, py_sr = sf.read(python_path)
    sw_audio, sw_sr = sf.read(swift_path)

    print(f"\n=== Comparison ===")
    print(f"Python: {len(py_audio)} samples @ {py_sr}Hz")
    print(f"Swift:  {len(sw_audio)} samples @ {sw_sr}Hz")

    # Align lengths
    min_len = min(len(py_audio), len(sw_audio))
    py = py_audio[:min_len]
    sw = sw_audio[:min_len]

    diff = py - sw
    print(f"Length diff: {abs(len(py_audio) - len(sw_audio))} samples")
    print(f"Max absolute error: {np.max(np.abs(diff)):.6f}")
    print(f"Mean absolute error: {np.mean(np.abs(diff)):.6f}")
    print(f"RMS error: {np.sqrt(np.mean(diff**2)):.6f}")

    # Correlation
    corr = np.corrcoef(py, sw)[0, 1]
    print(f"Correlation: {corr:.6f}")

    # SNR
    signal_power = np.mean(py ** 2)
    noise_power = np.mean(diff ** 2)
    if noise_power > 0:
        snr = 10 * np.log10(signal_power / noise_power)
        print(f"SNR: {snr:.1f} dB")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_lavasr_enhancement.py <input.wav> [swift_output.wav]")
        sys.exit(1)

    input_wav = sys.argv[1]
    output_dir = Path("/tmp/lavasr_validation")
    output_dir.mkdir(exist_ok=True)

    python_out = str(output_dir / "python_enhanced.wav")
    enhanced = enhance_python(input_wav, python_out)

    if len(sys.argv) >= 3:
        swift_out = sys.argv[2]
        compare_outputs(python_out, swift_out)
    else:
        print(f"\nTo compare with Swift output, re-run with:")
        print(f"  python {sys.argv[0]} '{input_wav}' <swift_enhanced.wav>")
