---
title: "How-to: use bash_completion to complete command"
slug: "how-to-use-bash_completion-to-complete-command"
date: 2015-08-20T22:14:55+08:00
author: "Jeffrey Su"
description: "如何使用 bash_completion 补全命令 对于Linuxer来说，自动补全是再熟悉不过的一个功能了。当你在命令行敲下部分的命令时，肯定会本能地按下Tab键补全完整的命令，当然除了命令补全之外，还有文件名补全。 自动补全这个功能是B…"
categories: ["技能矩阵"]
tags: ["linux"]
---

如何使用 bash\_completion 补全命令

对于Linuxer来说，自动补全是再熟悉不过的一个功能了。当你在命令行敲下部分的命令时，肯定会本能地按下Tab键补全完整的命令，当然除了命令补全之外，还有文件名补全。

自动补全这个功能是Bash自带的，但一般我们会安装bash-completion包来得到更好的补全效果，这个包提供了一些现成的命令补全脚本，一些基础的函数方便编写补全脚本，还有一个基本的配置脚本。但也正如之前说的，这个包不是必须的，只不过可以省些力气。

bash-completion这个包的安装位置因不同的发行版会有所区别，但是大致上启用的原理是类似的，一般会有一个名为bash\_completion的脚本，这个脚本会在shell初始化时加载。例如对于RHEL系统来说，这个脚本位于/etc/bash\_completion，而该脚本会由/etc/profile.d/bash\_completion.sh中导入：

```text
# Check for interactive bash and that we haven't already been sourced.
[ -z "$BASH_VERSION" -o -z "$PS1" -o -n "$BASH_COMPLETION" ] && return

# Check for recent enough version of bash.
bash=${BASH_VERSION%.*}; bmajor=${bash%.*}; bminor=${bash#*.}
if [ $bmajor -gt 3 ] || [ $bmajor -eq 3 -a $bminor -ge 2 ]; then
    if shopt -q progcomp && [ -r /etc/bash_completion ]; then
        # Source completion code.
        . /etc/bash_completion
    fi
fi
unset bash bmajor bminor
```

而在bash\_completion脚本中会加载/etc/bash\_completion.d下面的补全脚本：

```text
if [[ $BASH_COMPLETION_DIR != $BASH_COMPLETION_COMPAT_DIR && \
    -d $BASH_COMPLETION_DIR && -r $BASH_COMPLETION_DIR && \
    -x $BASH_COMPLETION_DIR ]]; then
    for i in $(LC_ALL=C command ls "$BASH_COMPLETION_DIR"); do
        i=$BASH_COMPLETION_DIR/$i
        [[ ${i##*/} != @(*~|*.bak|*.swp|\#*\#|*.dpkg*|*.rpm@(orig|new|save)|Makefile*) \
            && -f $i && -r $i ]] && . "$i"
    done
fi
unset i
```

补全脚本的名称一般就是命令名，这样比较容易查找：

```text
$ ls i*
iconv  iftop  ifupdown  info  iproute2  iptables
```

内置补全命令

Bash内置有两个补全命令，分别是compgen和complete。compgen命令根据不同的参数，生成匹配单词的候选补全列表，例如：

```text
$ compgen -W 'hi hello how world' h
hi
hello
how
```

compgen最常用的选项是-W，通过-W参数指定空格分隔的单词列表。h即我们在命令行当前键入的单词，执行完后会输出候选的匹配列表，这里是以h开头的所有单词。

complete命令的参数有点类似compgen，不过它的作用是说明命令如何进行补全，例如同样使用-W参数指定候选的单词列表：

```text
$ complete -W 'word1 word2 word3 hello' foo
$ foo w<Tab>
$ foo word<Tab>
word1  word2  word3
```

我们还可以通过-F参数指定一个补全函数：

$ complete -F \_foo foo

现在键入foo命令后，会调用\_foo函数来生成补全的列表，完成补全的功能，这一点正是补全脚本实现的关键所在，我们会在后面介绍。
补全相关的内置变量

除了上面的两个补全命令外，Bash还有几个内置的变量用来辅助补全功能，这里主要介绍其中三个：

COMP\_WORDS: 类型为数组，存放当前命令行中输入的所有单词；
COMP\_CWORD: 类型为整数，当前光标下输入的单词位于COMP\_WORDS数组中的索引；
COMPREPLY: 类型为数组，候选的补全结果；
COMP\_WORDBREAKS: 类型为字符串，表示单词之间的分隔符；
COMP\_LINE: 类型为字符串，表示当前的命令行输入；

例如我们定义这样一个补全函数\_foo：

```text
$ function _foo()
> {
>     echo -e "\n"
>
>     declare -p COMP_WORDS
>     declare -p COMP_CWORD
>     declare -p COMP_LINE
>     declare -p COMP_WORDBREAKS
> }
$ complete -F _foo foo
```

假设我们在命令行下输入以下内容，再按下Tab键补全：

```text
$ foo b

declare -a COMP_WORDS='([0]="foo" [1]="b")'
declare -- COMP_CWORD="1"
declare -- COMP_LINE="foo b"
declare -- COMP_WORDBREAKS="
\"'><=;|&(:"
```

对着上面的结果，我想应该比较容易理解这几个变量。当然正如我们之前据说，Bash-completion包并非是必须的，补全功能是Bash自带的。
编写脚本

补全脚本分成两个部分：编写一个补全函数和使用complete命令应用补全函数。后者的难度几乎忽略不计，重点在如何写好补全函数。难点在，似乎网上很少与此相关的文档，但是事实上，Bash-completion自带的补全脚本是最好的起点，可以挑几个简单的改改基本上就可以使用了。

一般补全函数(假设这里依然为\_foo)都会定义以下两个变量：

local cur prev

其中cur表示当前光标下的单词，而prev则对应上一个单词：

cur="${COMP\_WORDS[COMP\_CWORD]}"
prev="${COMP\_WORDS[COMP\_CWORD-1]}"

初始化相应的变量后，我们需要定义补全行为，即输入什么的情况下补全什么内容，例如当输入-开头的选项的时候，我们将所有的选项作为候选的补全结果：

```text
local opts="-h --help -f --file -o --output"

if [[ ${cur} == -* ]] ; then
COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
return 0
fi
```

不过再给COMPREPLY赋值之前，最好将它重置清空，避免被其它补全函数干扰。

现在完整的补全函数是这样的：

```text
function _foo() {
    local cur prev opts

    COMPREPLY=()

    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="-h --help -f --file -o --output"

    if [[ ${cur} == -* ]] ; then
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
}
```

现在在命令行下就可以对foo命令进行参数补全了：

```text
$ complete -F _foo foo
$ foo -
-f        --file    -h        --help    -o        --output
```

当然，似乎我们这里的例子没有用到prev变量。用好prev变量可以让补全的结果更加完整，例如当输入--file之后，我们希望补全特殊的文件（假设以.sh结尾的文件）：

```text
case "${prev}" in
-f|--file)
COMPREPLY=( $(compgen -o filenames -W "`ls *.sh`" -- ${cur}) )
;;
esac
```

现在再执行foo命令，--file参数的值也可以补全了：

```text
$ foo --file<Tab>
a.sh b.sh c.sh
```

###

### 参考链接

1. [An introduction to bash completion: part 2](http://www.debian-administration.org/article/317/An_introduction_to_bash_completion_part_2)
2. [Writing your own Bash Completion Function](http://fahdshariff.blogspot.com/2011/04/writing-your-own-bash-completion.html)
3. [Programmable Completion](http://www.gnu.org/software/bash/manual/html_node/Programmable-Completion.html#Programmable-Completion)
4. [Completion Files](http://devmanual.gentoo.org/tasks-reference/completion/index.html)
