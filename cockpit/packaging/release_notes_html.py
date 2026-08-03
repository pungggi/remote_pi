#!/usr/bin/env python3
"""Converte as notas da release (markdown do CHANGELOG) em HTML pro <description>
do appcast. O Sparkle/WinSparkle renderiza a description como HTML num webview:
markdown cru sai com os asteriscos na tela e, pior, com tudo numa linha só (HTML
colapsa quebras). Só a stdlib — roda em qualquer runner."""
import html
import re
import sys


def inline(text):
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', out)
    return out


def convert(md):
    lines = md.replace("\r\n", "\n").split("\n")
    parts = []          # blocos já fechados
    para = []           # parágrafo em construção
    items = []          # itens da lista em construção

    def flush_para():
        if para:
            parts.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()

    def flush_list():
        if items:
            parts.append(
                "<ul>" + "".join("<li>" + inline(i) + "</li>" for i in items) + "</ul>"
            )
            items.clear()

    for raw in lines:
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            flush_para()
            flush_list()
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush_para()
            flush_list()
            parts.append("<h3>" + inline(heading.group(2)) + "</h3>")
            continue
        bullet = re.match(r"^[-*+]\s+(.*)$", stripped)
        if bullet:
            flush_para()
            items.append(bullet.group(1))
            continue
        # Linha de continuação: o CHANGELOG quebra a ~80 colunas, então uma linha
        # indentada (ou logo após um item) pertence ao item/parágrafo anterior.
        if items and (raw.startswith((" ", "\t")) or not para):
            items[-1] += " " + stripped
            continue
        para.append(stripped)

    flush_para()
    flush_list()
    return "".join(parts)


STYLE = (
    "<style>"
    "body{font:13px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;"
    "margin:0;line-height:1.5}"
    "h3{font-size:12px;text-transform:uppercase;letter-spacing:.04em;"
    "opacity:.6;margin:14px 0 6px}"
    "h3:first-child{margin-top:0}"
    "p{margin:0 0 10px}"
    "ul{margin:0 0 10px;padding-left:18px}"
    "li{margin:0 0 5px}"
    "code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px;"
    "background:rgba(127,127,127,.15);padding:1px 4px;border-radius:3px}"
    "</style>"
)

def selftest():
    got = convert(
        "Resumo da versão.\n"
        "\n"
        "### Fixed\n"
        "- **Um item:** com `code` e uma quebra\n"
        "  de linha do CHANGELOG (~80 colunas).\n"
        "- Outro item com <tag> e & literais.\n"
    )
    expected = (
        "<p>Resumo da versão.</p>"
        "<h3>Fixed</h3>"
        "<ul>"
        "<li><strong>Um item:</strong> com <code>code</code> e uma quebra "
        "de linha do CHANGELOG (~80 colunas).</li>"
        "<li>Outro item com &lt;tag&gt; e &amp; literais.</li>"
        "</ul>"
    )
    assert got == expected, f"\n  esperado: {expected}\n  obtido:   {got}"
    # Nada de markdown cru sobrando nem tudo colapsado numa linha só.
    assert "**" not in got and "###" not in got
    print("release_notes_html: selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    body = convert(sys.stdin.read())
    sys.stdout.write(STYLE + body if body else "")
