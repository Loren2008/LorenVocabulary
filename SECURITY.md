# Security Policy

## Supported versions

Security fixes are applied to the latest revision of the `main` branch. Older commits and locally modified builds are not supported separately.

## Reporting a vulnerability

Do **not** open a public Issue for a vulnerability or an exposed credential. Use GitHub's private vulnerability reporting page:

<https://github.com/Loren2008/LorenVocabulary/security/advisories/new>

Include the affected commit, macOS version, reproduction steps, impact, and any suggested mitigation. Remove API keys, selected text, clipboard contents, database records, and other personal information from logs and screenshots.

The maintainer will aim to acknowledge a complete report within seven days. No guaranteed response or remediation timeline is offered.

## Security boundaries

- The application needs Accessibility permission to detect the global shortcut and synthesize Copy.
- Selected text may be sent to configured network services only when local lookup paths do not provide the requested result.
- API keys belong in `~/.ielts-vocab/Config.plist` or an environment variable, never in the repository or App Bundle.
- `setup_local_signing.sh` creates a local development identity. It is not Apple notarization and must not be treated as a distribution certificate.
- User-provided SQLite databases and third-party services are outside the project's trust boundary.
