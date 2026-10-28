---
title: "How-to start my first project on GitLab"
slug: "how-to-start-my-first-project-on-gitlab"
date: 2016-09-26T16:00:25+08:00
author: "Jeffrey Su"
description: "1. login as Administrator and create test group/project/user create test group - test create test user - test change tes…"
categories: ["Skills Matrix"]
tags: ["GitLab", "linux"]
---

1. login as Administrator and create  test group/project/user

create test group - test create test user   - test change test user to test group and change `Project access` role to owner create a demo project -- http://git.suzf.net/test/demo -- Visibility Level can chose public for test at the end, click Create project button

2. use the test user - test login and and an SSH key

click avatar img --> profile setting --> SSH keys on linux git client generate a ssh key for gitlab

```
cd $HOME
ssh-keygen -t rsa -C "username@suzf.net" -f .ssh/gitlab_rsa
```

reslove multi ssh key issue

```
cat  >> $HOME/.ssh/config << EOF
Host git.suzf.net
    IdentityFile ~/.ssh/gitlab_rsa
    User git
    Port 22
EOF
```

paste the ssh keys public public, the example file is .ssh/gitlab\_rsa.pub now `cat  .ssh/gitlab\_rsa.pub` and then copy the output to Key area. set up an title for this ssh key.

3. test the git connection

^\_^[15:49:55][zfsu@lucy ~]$ssh -T git.suzf.net Welcome to GitLab, zfsu!

4. checkout and commit

Git global setup

```
git config --global user.name "Administrator"
git config --global user.email "admin@example.com"
```

Create a new repository

```
git clone git@git.suzf.net:test/demo.git
cd demo
touch README.md
git add README.md
git commit -m "add README"
git push -u origin master
```

Existing folder or Git repository

```
cd existing_folder
git init
git remote add origin git@git.suzf.net:test/demo.git
git add .
git commit
git push -u origin master
```

Reference:

[1] http://wenva.github.io/git/2016/03/11/%E5%85%B3%E4%BA%8EGitlab%E8%8B%A5%E5%B9%B2%E6%9D%83%E9%99%90%E9%97%AE%E9%A2%98.html

[2] http://www.cnblogs.com/xxcanghai/p/5009926.html
