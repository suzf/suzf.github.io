#!/bin/bash
# Build Hugo site and deploy it to branch gh-pages

# Readline library accepts \001 and \002 as non-visible text delimiters
# The bash-specific \[ and \] are translated to \001 and \002
nvt_open=$'\001' # non-visible text open
nvt_close=$'\002' # non-visible text close

# Enable color in terminal with tput and non-visible text delimiters
tput_red=${nvt_open}$(tput setaf 1)${nvt_close}
tput_green=${nvt_open}$(tput setaf 2)${nvt_close}
tput_reset=${nvt_open}$(tput sgr0)${nvt_close}

# Check if there is any pending change in branch main
if [[ $(git status -s) ]]; then
  echo "${tput_red}ERROR: The working directory is dirty, please commit all pending changes${tput_reset}"
  exit 1
fi

# Remove all existing files in public folder
echo "${tput_green}INFO: 1.Removing all existing files in public folder...${tput_reset}"
rm -rf public/*

# Generate Hugo site
echo "${tput_green}INFO: 2.Generating Hugo site...${tput_reset}"
hugo --gc --environment production
if [[ $? -ne 0 ]]; then
  echo "${tput_red}ERROR: Failed to generate Hugo site${tput_reset}"
  exit 1
fi

# Deploy Hugo site
echo "${tput_green}INFO: 3.Deploying Hugo site to branch gh-pages...${tput_reset}"

# Go into worktree subdirectory of branch gh-pages
cd public

# Commit all changes to branch gh-pages
git add --all

# Push to remote branch gh-pages
if [[ $# -eq 1 ]]; then
  commit_msg="$1"
else
  commit_msg="Update site on $(date '+%b %d, %Y')"
fi
git commit -m "$commit_msg"

git push origin gh-pages
if [[ $? -ne 0 ]]; then
  echo "${tput_red}ERROR: Failed to deploy Hugo site to branch gh-pages${tput_reset}"
  exit 1
fi

# Done
echo "${tput_green}INFO: 4.Done${tput_reset}"
