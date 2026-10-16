#!/usr/bin/env python3
"""生成 Sparkle 的 appcast.xml（只保留最新版本，Sparkle 只需要最新那一条）。
用法：make-appcast.py 版本号 zip路径 'sparkle:edSignature="..." length="..."' 更新说明文件 > appcast.xml
"""
import sys, html, email.utils, re

version, zip_path, sig_attrs, notes_file = sys.argv[1:5]
name = zip_path.split("/")[-1]
url = f"https://github.com/Zhengmingming1/Launchy/releases/download/v{version}/{name}"
notes = open(notes_file, encoding="utf-8").read().strip()
# sign_update 的输出形如：sparkle:edSignature="xxx" length="123"
if not re.search(r'sparkle:edSignature="[^"]+"', sig_attrs):
    sys.exit("签名输出不对")
items = "".join(f"<li>{html.escape(l.lstrip('-* ').strip())}</li>" for l in notes.splitlines() if l.strip())

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>启动台助手 Launchy</title>
    <link>https://github.com/Zhengmingming1/Launchy</link>
    <language>zh-CN</language>
    <item>
      <title>版本 {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h3>启动台助手 {version} 更新内容</h3><ul>{items}</ul>]]></description>
      <enclosure url="{url}" type="application/octet-stream" {sig_attrs} />
    </item>
  </channel>
</rss>""")
