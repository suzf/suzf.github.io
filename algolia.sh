#!/bin/bash
# Update Algolia objects

# Readline library accepts \001 and \002 as non-visible text delimiters
# The bash-specific \[ and \] are translated to \001 and \002
nvt_open=$'\001' # non-visible text open
nvt_close=$'\002' # non-visible text close

# Enable color in terminal with tput and non-visible text delimiters
tput_red=${nvt_open}$(tput setaf 1)${nvt_close}
tput_green=${nvt_open}$(tput setaf 2)${nvt_close}
tput_reset=${nvt_open}$(tput sgr0)${nvt_close}

index_list="
index.zh-cn:public/index.json
index.en:public/en/index.json
"

for index_item in ${index_list}; do
  index_name=${index_item%%:*}
  index_json=${index_item#*:}
  index_ndjson=${index_json/.json/.ndjson}

  echo "${tput_green}INFO: Clearing ${index_name}...${tput_reset}"
  algolia index clear ${index_name} -y

  echo "${tput_green}INFO: Converting ${index_json} into ${index_ndjson}...${tput_reset}"
  jq -c '.[]' ${index_json} > ${index_ndjson}

  echo "${tput_green}INFO: Importing ${index_name} objects from ${index_ndjson}...${tput_reset}"
  algolia objects import ${index_name} -F ${index_ndjson}
done
