---
# Home page title: <title>, og:title and twitter:title. Posts keep the
# " - Suzf Blog" suffix from the site title.
title: "Suzf Blog — DevOps & Developer Notes"
# og:locale for every English page. Hugo's built-in Open Graph template takes
# a page's `locale` param before languageCode, and languageCode has to stay
# "en" (it is the <html lang> and matches the tools site), which would give
# og:locale "en" instead of the language_TERRITORY form Open Graph expects.
cascade:
  params:
    locale: en-US
---
