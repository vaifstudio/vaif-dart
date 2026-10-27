# Contributing

This repository is the published copy of the VAIF Studio Dart SDK. VAIF Studio
develops the SDK in its own source repository, together with the API it calls
and the generator for `lib/src/generated/operations.dart`, and updates this
repository from there.

## Issues

Bug reports and feature requests are welcome as GitHub issues. For a bug,
include the `vaif_client` version or commit, your Dart or Flutter version and
platform, what you expected, what happened, and a minimal program that
reproduces it. Remove API keys, tokens and personal data from anything you
paste.

Report security vulnerabilities privately as described in
[SECURITY.md](SECURITY.md), not in an issue.

## Local development

The package supports Dart 3.7 and later. Running its tests needs Dart 3.11 or
later, which the current release of `package:test` requires.

```sh
dart pub get
dart format --output=none --set-exit-if-changed lib test example
dart analyze --fatal-infos
dart test
```

The unit tests replace HTTP with `package:http/testing`, and the realtime tests
use a WebSocket server on the loopback interface, so they need no network
access or VAIF Studio project. `test/integration_test.dart` runs against a
live project only when `VAIF_IT_BASE_URL`, `VAIF_IT_PROJECT_ID` and
`VAIF_IT_API_KEY` are set, and skips itself otherwise. The test that checks the
generated operations against the API's OpenAPI contract runs only when
`VAIF_API_CONTRACT` names the contract file, which this repository does not
include.

To check that the package still compiles for the web:

```sh
dart compile js -o build/example.js example/main.dart
dart compile wasm -o build/example.wasm example/main.dart
```

`lib/src/generated/operations.dart` is generated from the API's OpenAPI
contract. Do not edit it by hand; describe the change you need in an issue
instead.

## Pull requests

Pull requests are reviewed by the maintainers. Because this repository is
updated from the source repository, an accepted pull request is applied there
by a maintainer, with credit to you, and reaches this repository with the next
update. For anything larger than a small fix, open an issue first so the
approach can be agreed before you write the code.

## Code of conduct

Participation in this project is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).
