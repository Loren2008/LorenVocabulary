# Third-party notices

LorenVocabulary's own source code and repository documentation are released under the MIT License. The project interoperates with components and services governed by separate terms.

## Runtime components

- Apple Swift, SwiftUI, AppKit, AVFoundation, ApplicationServices, CoreServices, and DictionaryServices are provided by macOS/Xcode under Apple's terms. They are not relicensed or redistributed by this repository.
- SQLite is linked from macOS. SQLite states that its source is in the public domain; this repository does not vendor SQLite source.
- Free Dictionary API may be contacted as a network fallback. Its content and service remain subject to the provider's terms.
- DeepSeek is optional. API access and generated outputs remain subject to DeepSeek's applicable terms and the user's account agreement.

## Optional data-build tools

- `wordfreq` is an optional development dependency. Its software and its underlying data sources have their own notices and licenses.
- `lemminflect` is an optional development dependency with its own license.
- macOS `/usr/share/dict` word lists and locale/CLDR-derived names may be used as candidate evidence. Downstream distributors must independently verify the licenses that apply to generated datasets.

## Excluded data

The public repository does not include the historical full `words.db`, API credentials, generated candidate manifests, macOS dictionary output, or personal learning data. Their omission is deliberate and prevents the MIT license from being misread as a grant covering unverified third-party material.

No affiliation or endorsement by Apple, DeepSeek, Oxford University Press, IELTS, Cambridge University Press & Assessment, the British Council, or IDP Education is claimed.
