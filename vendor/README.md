# Offline dependencies

These files are the app's pinned rendering dependencies, homepage font and model capacity catalog. The
app and its build do not download scripts or fonts from a CDN. Preview, selected
references and AI replies use the same rendering stack.

`assets.json` is the source of package versions, license identifiers, original
download and license URLs, and SHA-256 checksums for every bundled script, license,
stylesheet and font. Packaged files must match this manifest. KaTeX's stylesheet
intentionally retains only
WOFF2 font sources for the iOS 26 baseline; its fonts are unchanged upstream files.

`scripts/build_native_web.py` checks the checksums before packaging. Web dependency
licenses are copied alongside the libraries in `MarkdownIt/Resources/Web` and
into the app. Mermaid's bundled license-information comment is part of the original
script and must remain intact. Lucide's license file includes both its ISC and MIT
notices. DOMPurify is distributed here under its upstream Apache-2.0 option.
Project licensing does not replace these dependency licenses.

`model-capabilities.json` is a native-only snapshot of Models.dev capacities,
resolved from the Git revision recorded in the file and manifest. It retains
provider overrides and exact model IDs; entries require an explicit HTTPS
service endpoint. The app uses it only to supplement missing metadata for that
same service and model. It does not fetch Models.dev at runtime or infer a
proxy's limits from an upstream model name. The MIT notice is bundled alongside
the catalog. Refresh it with `scripts/update_model_catalog.py --revision FULL_GIT_SHA`;
the script records the source archive and generated output checksums. Review
the resulting capacity changes before publishing an app update.

The Newsreader font and its license have `target: native` in the manifest. Xcode
copies them directly into the app bundle; `UIAppFonts` registers the font for the
homepage slogan. They are not included in the Web rendering stack. Both files
are pinned to the upstream commit in their download URLs and checked by the same
manifest validation.

To update a dependency, review its upstream release and security advisories,
replace the script and license together, update the version, URLs and checksums,
then regenerate resources and run both simulator families. A checksum identifies
the reviewed bytes; it does not establish that a dependency has no vulnerabilities.

## CJK emphasis bundle

`markdown-it-cjk-friendly.js` bundles the upstream ESM plugin and its pinned
`get-east-asian-width` dependency for the existing classic-script reader. The
combined license file retains both upstream MIT notices. `assets.json` records
the source checksum, compiler parameters and bundled dependency; the advisory
check includes the bundled package. Normal app builds copy the checked bundle
without invoking npm or downloading dependencies.

Reproduce the bundle from the repository root:

```sh
cjk_build_dir=$(mktemp -d)
npm --prefix "$cjk_build_dir" install --ignore-scripts --no-audit --no-fund --save-exact \
  markdown-it-cjk-friendly@3.0.0 get-east-asian-width@1.4.0 esbuild@0.25.12
"$cjk_build_dir/node_modules/.bin/esbuild" \
  "$cjk_build_dir/node_modules/markdown-it-cjk-friendly/dist/index.js" \
  --bundle --format=iife --global-name=MarkdownItCjkFriendly --platform=browser \
  --target=safari18 --minify --legal-comments=inline \
  --outfile=vendor/markdown-it-cjk-friendly.js
rm -rf "$cjk_build_dir"
```

When upgrading, update the bundle, both notices, the pinned versions and checksums
together. Compare the CommonMark conformance examples before and after enabling
the plugin, then verify CJK text, escaped markers, code, math and all reader
surfaces on both simulator families.
