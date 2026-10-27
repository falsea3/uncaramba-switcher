#!/bin/zsh
# Скачивает исходные данные и собирает model/ru.bin и model/en.bin.
#   субтитры (частоты):  FrequencyWords — OpenSubtitles 2018
#   словоформы:          danakt/russian-words (MIT), dwyl/english-words (Unlicense)
#   сленг:               data/slang_ru.txt, data/slang_en.txt (правятся руками)
set -e
cd "$(dirname "$0")/.."

mkdir -p data/raw data/clean model build/tools
fetch() { [[ -f $2 ]] || curl -sfL -o $2 $1; }
fetch https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_full.txt data/raw/ru_full.txt
fetch https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt data/raw/en_full.txt
fetch https://raw.githubusercontent.com/danakt/russian-words/master/russian.txt data/raw/ru_dict.txt
fetch https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt data/raw/en_dict.txt

swiftc -O -swift-version 5 tools/BuildModel.swift -o build/tools/BuildModel -framework Cocoa
for l in ru en; do
  build/tools/BuildModel $l data/raw/${l}_full.txt data/raw/${l}_dict.txt data/slang_$l.txt data/clean model/$l.bin
done
