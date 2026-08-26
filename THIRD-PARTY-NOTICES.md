# Third-party notices

Miri depends on the following open-source software and model conversions.
Miri's complete Apache License 2.0 text is distributed in [`LICENSE`](LICENSE).

## FluidAudio

Miri's local speech stack is powered by
[FluidAudio](https://github.com/FluidInference/FluidAudio), created by the
FluidInference Team and licensed under the Apache License 2.0.

Miri uses FluidAudio for:

- CoreML model discovery, download, caching, loading, and compilation;
- NVIDIA Parakeet TDT v3 automatic speech recognition;
- PocketTTS streaming text-to-speech;
- Apple Neural Engine/CoreML execution; and
- the NemoTextProcessing binary used transitively by FluidAudio for text
  normalization.

Citation:

> FluidInference Team. (2025). *FluidAudio: Local Speaker Diarization, ASR,
> and VAD for Apple Platforms* [Computer software].
> https://github.com/FluidInference/FluidAudio

FluidAudio source: https://github.com/FluidInference/FluidAudio  
FluidAudio license: https://github.com/FluidInference/FluidAudio/blob/main/LICENSE

## NVIDIA Parakeet TDT 0.6B v3

Miri uses the NVIDIA Parakeet TDT 0.6B v3 speech-recognition model, converted
and optimized for CoreML by the FluidInference Team. The model is licensed
under Creative Commons Attribution 4.0 International (CC-BY-4.0).

Original model creator: NVIDIA Corporation and affiliates  
Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3  
CoreML conversion: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml  
Conversion tooling: https://github.com/FluidInference/mobius  
License: https://creativecommons.org/licenses/by/4.0/

Miri does not modify or redistribute these weights in its application bundle.
FluidAudio downloads the CoreML conversion after explicit user consent.

## PocketTTS

Miri uses PocketTTS, created by Kyutai, through FluidInference's CoreML
conversion. The downloaded model repository is licensed under CC-BY-4.0 and
requires attribution to Kyutai.

Original model creator: Kyutai  
Original model: https://huggingface.co/kyutai/pocket-tts  
Original project: https://github.com/kyutai-labs/pocket-tts  
CoreML conversion: https://huggingface.co/FluidInference/pocket-tts-coreml  
License: https://creativecommons.org/licenses/by/4.0/

Miri uses the English model and the `alba` voice by default. Miri does not
modify or redistribute these weights in its application bundle. FluidAudio
downloads them after explicit user consent.

## NemoTextProcessing

FluidAudio resolves the `NemoTextProcessing` binary from
[text-processing-rs](https://github.com/FluidInference/text-processing-rs),
which includes grammars and fixtures derived from NVIDIA NeMo Text Processing.
It is Apache-2.0 licensed and includes permissively licensed Rust dependencies.

Source: https://github.com/FluidInference/text-processing-rs  
NVIDIA NeMo source: https://github.com/NVIDIA/NeMo-text-processing  
License: https://www.apache.org/licenses/LICENSE-2.0
