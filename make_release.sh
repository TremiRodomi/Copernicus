#!/bin/bash
# Release builds (NOTES pass 50): a clean staging copy of the game folder, then dragonruby-publish.
#   ./make_release.sh            -> dragonruby-linux-amd64/builds/
# The staging copy holds ONLY the code, metadata (icons), audio sets and the player READMEs: never data/ (the player's
# ROMs / disk), save.txt, settings.txt or the border pictures of the dev folder.
set -e
cd "$(dirname "$0")/dragonruby-linux-amd64"
rm -rf copernicus builds
mkdir -p copernicus/data copernicus/borders
cp -r fairyland/app fairyland/metadata fairyland/audio copernicus/
rm -f copernicus/audio/README.md copernicus/metadata/dragonruby_production_build
cp fairyland/data/README.txt copernicus/data/
cp fairyland/borders/README.txt copernicus/borders/
./dragonruby-publish --platforms=windows-amd64,linux-amd64,macos --package copernicus
ls -la builds
