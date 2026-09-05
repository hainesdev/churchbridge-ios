# Third-party notices

The ChurchBridge iPhone app builds on third-party work. This file records what,
and under which terms.

The app's own code is licensed separately — see [`LICENSE`](LICENSE) and
[`LICENSE-FAQ.md`](LICENSE-FAQ.md). Nothing here changes those terms, and they
do not apply to the components below.

## DeepFilterNet — speech enhancement architecture

- **Upstream:** https://github.com/Rikorose/DeepFilterNet
- **Copyright:** © 2021 Hendrik Schröter
- **License:** MIT (upstream offers MIT or Apache-2.0 at the user's option;
  this project elects MIT)
- **Full license text:** [`LICENSE-DEEPFILTERNET`](LICENSE-DEEPFILTERNET)

`ChurchBridgeTranslation/DeepFilterNet3Processor.swift` and
`ChurchBridgeTranslation/DeepFilterNet3_Streaming.swift` implement the
DeepFilterNet3 streaming signal chain — STFT analysis and synthesis, the ERB
filterbank and its inverse, deep-filter application, overlap-add memory, and
running normalisation — in Swift against Accelerate. The architecture,
coefficients, and processing order are DeepFilterNet's; the Swift
implementation is not.

Upstream asks that use of the DeepFilterNet3 model be cited:

> Schröter, H., Rosenkranz, T., Escalante-B., A. N., and Maier, A.
> "DeepFilterNet: Perceptually Motivated Real-Time Speech Enhancement."
> INTERSPEECH, 2023.

## soniqo/speech-swift — auxiliary-data loading

- **Upstream:** https://github.com/soniqo/speech-swift
- **License:** Apache License 2.0
- **Full license text:** [`LICENSE-APACHE-2.0`](LICENSE-APACHE-2.0)

Portions of `ChurchBridgeTranslation/DeepFilterNet3Processor.swift` are derived
from this project: the `.npz` / `.npy` auxiliary-data loading, specifically
`parseNpy`, `loadAuxiliaryData`, and the `readUInt16` / `readUInt32` /
`readUInt64` helpers, including the ZIP64 handling used to read the model's
auxiliary archive.

**That file has been modified from the original**, as required by section 4(b)
of the Apache License. The surrounding STFT, ERB filterbank, deep-filter
application, tuning, and streaming logic are not from this source.

The upstream project ships no `NOTICE` file, so there is none to reproduce here.

## DeepFilterNet3 model weights

The neural network is an INT8-palettized Core ML conversion of DeepFilterNet3
published by a third party at
[aufklarer/DeepFilterNet3-CoreML](https://huggingface.co/aufklarer/DeepFilterNet3-CoreML)
under the Apache License 2.0, with `Rikorose/DeepFilterNet3` as its base model.

The app **downloads these assets at runtime** from the ChurchBridge platform and
does not bundle them, so no model weights are committed to this repository.

## Apple frameworks and sample code

The audio capture design follows Apple's published guidance and sample code for
`AVAudioEngine` voice processing. No Apple sample code is included in this
repository; it was used as reference material only.

## Bible text

Scripture data is not covered by this project's license. Public-domain
translations (ASV, KJV) carry no restriction. **Reina-Valera 1960 is
copyrighted** by Sociedades Bíblicas Unidas / American Bible Society and is not
redistributed by this repository.
