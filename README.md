# Suzf Blog

Jeffrey Su 的运维与开发笔记，线上地址 <https://suzf.net/blog/>，中英双语（英文在 `/blog/`，中文在 `/blog/zh-cn/`）。

用 Hugo 0.154.5 extended 构建，主题是 [LoveIt](https://github.com/dillonzq/LoveIt)，以 git submodule 的形式放在 `themes/LoveIt`。主站 suzf.net 的源码在 [suzf/mysite](https://github.com/suzf/mysite)。

## 本地开发

首次克隆后拉取主题：

```bash
git submodule update --init
```

本地预览（包含草稿和未来日期的文章）：

```bash
./server.sh
```

`baseURL` 是 `https://suzf.net/blog`，所以本地预览地址是 <http://localhost:1313/blog/>。

新建文章：

```bash
./create.sh
```

文章放在 `content/posts/<年份>/<目录>/` 下，每种语言一个文件：`index.en.md` 和 `index.zh-cn.md`。front matter 里的 `description` 会用作搜索结果里的描述；留空时，取正文摘要的前 155 个字符。

## 部署

线上的 `/blog/` 由 `deploy/pages.yml` 部署：把 `public/` 打包上传到服务器的 `/opt/data/www/blog.suzf.net/`，再由 nginx 提供。

先构建，再部署：

```bash
hugo --gc --cleanDestinationDir --environment production
```

```bash
ansible-playbook -i deploy/inventory.ini deploy/pages.yml
```

一定要先构建。`pages.yml` 只在 `public/index.html` 不存在时才会自己构建；只要 `public/` 里还有上次的产物，它就会把旧内容原样部署上去。

`deploy.sh` 是另一套流程，把 `public/` 推送到 `gh-pages` 分支，不会更新 suzf.net/blog。

### Cloudflare 缓存清理

部署最后会清理 suzf.net 的 Cloudflare 缓存，让新内容立即生效。需要在运行部署的机器上设置 `CF_API_TOKEN` 和 `CF_ZONE_ID` 两个环境变量。没设置时跳过清理并打印警告，部署照常完成。

token 的权限、Zone ID 的位置、凭据的保存方法，以及清理失败时的表现，和主站一样，详见 [suzf/mysite 的 README](https://github.com/suzf/mysite#cloudflare-缓存清理)。两个仓库共用同一组凭据。

## 对主题的覆盖

以下文件覆盖了 `themes/LoveIt` 里的同名模板，主要用于 SEO 修正。升级主题时要和新版本的对应文件逐个对比。各文件的修改原因都写在文件开头的注释里。

| 文件 | 改了什么 |
|---|---|
| `layouts/_default/baseof.html` | 标签页和分类页加 `noindex, follow`；首页 `<title>` 使用 `content/_index.<lang>.md` 里的标题；接入 AdSense |
| `layouts/_partials/head/meta.html` | 每篇文章输出自己的 meta description，而不是全站统一的描述 |
| `layouts/_partials/head/hreflang.html` | 中英文页面互相声明 hreflang（en、zh-CN、x-default） |
| `layouts/sitemap.xml` | 不收录标签和分类页；hreflang 使用 `zh-CN` |
| `layouts/posts/single.html` | 文章页的目录标题不再是 h2，避免出现在 h1 之前 |
| `layouts/_default/summary.html` | 首页文章卡片的标题从 h1 改为 h2 |
| `layouts/_default/section.html` | 列表页的标题从 h2 改为 h1 |
| `layouts/_default/taxonomy.html` | 标签和分类页按年份分组 |
| `assets/css/_custom.scss` | 列表页标题改为 h1 后，保持原来的字号 |
| `layouts/_partials/internal/`、`layouts/shortcodes/` | 兼容 Hugo 0.154 的 X/Twitter 嵌入 |

其他相关配置在 `hugo.toml` 里：

- **RSS 链接**：各语言的 `params.social.RSS.url` 写成不带开头斜杠的 `index.xml`。主题默认的 `/index.xml` 会跳过 `/blog` 前缀。
- **作者链接**：各语言的 `params.author.link` 会原样输出，所以要写完整路径，包括 `/blog/` 前缀。
- **分享图**：`params.images` 指向主站的 1200×630 分享图 `https://suzf.net/og`。
