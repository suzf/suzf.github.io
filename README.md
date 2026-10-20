# Suzf Blog

Jeffrey Su 的运维与开发笔记，线上地址 <https://suzf.net/blog/>，中英双语（英文在 `/blog/`，中文在 `/blog/zh-cn/`）。

用 Hugo 0.154.5 extended 构建，主题是 [LoveIt](https://github.com/dillonzq/LoveIt)，以 git submodule 的形式放在 `themes/LoveIt`。主站 suzf.net 的源码在 [suzf/mysite](https://github.com/suzf/mysite)。

## 本地开发

首次克隆后拉取主题：

```bash
git submodule update --init
```

首次克隆后，启用仓库里的提交身份（`.gitconfig`，Jeffrey <i@suzf.net>）。git 出于安全原因不会自动加载仓库里的配置文件，所以每个克隆要运行一次：

```bash
git config include.path ../.gitconfig
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

## 文章分享图

每篇文章在构建时生成一张 1200×630 的分享图（`/blog/og/<语言>/posts/<文章>-<哈希>.png`），用作 og:image、twitter:image 和结构化数据里的图片。底图是和主站 `suzf.net/og` 同色的渐变（`assets/images/og-base.png`），上面画"Suzf Blog"、文章标题和"suzf.net/blog"。

- **字体**：构建时向 Google Fonts 请求 Noto Sans SC Bold，只要这张图用到的字（`text=` 参数），返回几十 KB 的 TrueType 子集。Hugo 会把它缓存在 `~/.cache/hugo_cache`，所以只有新文章或改过标题的文章需要联网。
- **拿不到字体时**：构建照常成功，会打印一条 `og-card:` 警告，这篇文章退回用通用的 `suzf.net/og` 分享图。
- **换行**：`images.Text` 只会在空格处换行，纯中文标题会超出画面，所以模板自己断行：按估算宽度，尽量让各行一样长，中文的右括号、逗号等不放行首。标题三行放不下时缩小字号，还放不下就截断加省略号。
- **文件名里的哈希**：由标题和断行结果算出。改了标题就换新网址，不会被 CDN 或浏览器缓存成旧图。

## 对主题的覆盖

以下文件覆盖了 `themes/LoveIt` 里的同名模板，主要用于 SEO 修正。升级主题时要和新版本的对应文件逐个对比。各文件的修改原因都写在文件开头的注释里。

| 文件 | 改了什么 |
|---|---|
| `layouts/_default/baseof.html` | 标签页和分类页加 `noindex, follow`；首页 `<title>` 使用 `content/_index.<lang>.md` 里的标题，分页第 2 页起加"第 N 页"；接入 AdSense |
| `layouts/_partials/head/meta.html` | 每篇文章输出自己的 meta description，而不是全站统一的描述 |
| `layouts/_partials/head/hreflang.html` | 中英文页面互相声明 hreflang（en、zh-CN、x-default） |
| `layouts/_partials/head/link.html` | 首页分页第 2 页起的 canonical 指向自身，不再指向第 1 页 |
| `layouts/_partials/head/seo.html` | About 页输出 ProfilePage + Person，不再是 BlogPosting；归档页输出 CollectionPage；文章的结构化数据图片用自己的分享图，author 带上 About 页链接 |
| `layouts/_partials/_funcs/get-page-images.html` | 覆盖 Hugo 内置模板取 og:image / twitter:image 的逻辑：文章用自己的分享图，其他页面照旧用 `params.images` |
| `layouts/index.html` | 首页文章分页改由 `layouts/_partials/function/home-pager.html` 生成，和 `<head>` 共用同一个分页器（原因见该文件注释） |
| `layouts/sitemap.xml` | 不收录标签和分类页；hreflang 使用 `zh-CN` |
| `layouts/posts/single.html` | 文章页的目录标题不再是 h2，避免出现在 h1 之前；`<title>` 加上 " - Suzf Blog" 超过 60 个字符时去掉后缀 |
| `layouts/_default/summary.html` | 首页文章卡片的标题从 h1 改为 h2 |
| `layouts/_default/section.html` | 列表页的标题从 h2 改为 h1，年份分组从 h3 改为 h2 |
| `layouts/_default/taxonomy.html` | 标签和分类页按年份分组 |
| `assets/css/_custom.scss` | 列表页标题和年份分组升级标签后，保持原来的字号 |
| `i18n/` | 主题没有的文案（分页标题里的"第 N 页"），和主题的 i18n 合并 |
| `layouts/_partials/function/og-card.html`、`og-card-wrap.html`、`assets/images/og-base.png` | 每篇文章的分享图（不是主题覆盖，是新增的），见下 |
| `layouts/_partials/internal/`、`layouts/shortcodes/` | 兼容 Hugo 0.154 的 X/Twitter 嵌入 |

其他相关配置在 `hugo.toml` 里：

- **RSS 链接**：各语言的 `params.social.RSS.url` 写成不带开头斜杠的 `index.xml`。主题默认的 `/index.xml` 会跳过 `/blog` 前缀。
- **作者链接**：各语言的 `params.author.link` 会原样输出，所以要写完整路径，包括 `/blog/` 前缀。
- **分享图**：`params.images` 指向主站的 1200×630 分享图 `https://suzf.net/og`；结构化数据用的 `params.seo.image` 也指向它。
- **出版者**：`params.page.seo.publisher` 和主站的 Organization 一致（名称 Suzf，logo `https://suzf.net/logo`）。
- **图标**：`params.app.noFavicon = true`。主题会引用站点根目录下的 `/favicon-32x32.png` 等文件，但根目录是主站，没有这些文件。现在由浏览器自动回退到主站提供的 `/favicon.ico` 和 `/apple-touch-icon.png`。
- **标题层级**：文章正文的小节标题从 `##` 开始（文章标题是 h1）。
- **资源指纹**：`params.fingerprint = "sha256"`，主题自己的 CSS/JS 文件名里带内容哈希（并加上 SRI 的 `integrity`），改样式后 Cloudflare 和浏览器不会继续用旧文件。只在 `--environment production` 下生效。
