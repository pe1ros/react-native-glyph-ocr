# Contributing

Contributions are welcome. Please follow the [code of conduct](CODE_OF_CONDUCT.md).

## Setup

The repository is a Yarn workspace: the library in the root, an example app in `example/`.
Use the Node.js version from [`.nvmrc`](.nvmrc) and run in the root:

```sh
yarn
```

npm does not work for development here: the workspace needs Yarn 4, which `.yarnrc.yml` pins.

## Everyday commands

```sh
yarn typecheck        # TypeScript: the library, the example and the Expo plugin
yarn lint             # ESLint + Prettier (yarn lint --fix to format)
yarn test             # Jest unit tests
yarn prepare          # builds lib/ and plugin/build, as npm publish does

yarn example start    # Metro for the example
yarn example ios      # build and run on iOS
yarn example android  # build and run on Android
```

The example app uses the library's sources directly, so JavaScript changes need no rebuild; native
changes do. Its **Self-test** tab checks the whole API on a device or simulator: sources, EXIF, ROI,
output modes, camera-like frames, the frame meter, cancelling and errors. Run it after native
changes on both platforms and expect `0 failed`. Each line is also logged with a `[selftest]` prefix.

Native code: open `example/ios/GlyphOcrExample.xcworkspace` (the pod is under
`Pods > Development Pods > NitroGlyphOcr`) or `example/android` in Android Studio.

## Nitro bindings

`nitrogen/generated` is generated from `src/specs/*.nitro.ts` and committed, so the package builds
without a code generation step. After changing a spec:

```sh
yarn nitrogen
```

Use the nitrogen version pinned in `package.json`: it must match the `react-native-nitro-modules`
version the package supports. CI fails when the committed bindings differ from a fresh run.

Two limits of nitrogen shaped the specs: an optional `string[]` inside a struct does not compile in
Swift (so `customWords` belong to `createOcr`), and a `UInt64` inside a struct does not compile in
Kotlin (so `createTestFrame` returns the pointer alone).

## Models

`models/manifest.json` and the dictionaries in `models/pp-ocrv5/` are generated from the pinned
Hugging Face revisions:

```sh
yarn manifest          # rebuild
yarn manifest --check  # fail if models/ is out of date
```

The ExecuTorch runtime (optional, Android arm64) is built with
[`scripts/executorch/build-android.sh`](scripts/executorch/build-android.sh) into the git-ignored
`android/executorch`; `export_pte.py` exports the `.pte` programs.

## Pull requests

- Keep a pull request to one change, with tests where they make sense.
- Make sure `yarn typecheck`, `yarn lint` and `yarn test` pass.
- For API changes, open an issue first.
- Add a line to [CHANGELOG.md](CHANGELOG.md) under the unreleased version.

## Releasing

1. Update `version` in `package.json` (the podspec reads it) and move the CHANGELOG entries under
   that version.
2. Commit, tag `v<version>` and push the tag.
3. `npm publish` (npm runs the `prepare` script, which builds `lib/` and the plugin), then create a GitHub release with the
   CHANGELOG entry.
