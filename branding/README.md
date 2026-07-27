# Branding — Piper

Identidade visual oficial do fork (Piper). Fonte de verdade: arquivos SVG
(escaláveis). PNGs derivados são gerados via `@resvg/resvg-js` (ver abaixo).

## O mark

Um **"P" geométrico** cujo traço vertical é um *pipe* (conduto), com um
**pacote de dados** (bolinha azul) dentro da tigela — "data piped between your
devices". Construído em retângulos arredondados (mesma linguagem geométrica do
π anterior), peso de traço uniforme, dentro da safe zone Android (~66% central).

## Paleta

| Cor | Hex | Uso |
|---|---|---|
| Preto puro | `#000000` | Background (full + adaptive icon bg) |
| Branco puro | `#FFFFFF` | "P" (foreground principal) |
| Azul Piper | `#4FC3F7` | Pacote de dados (accent) |

## Arquivos

| Arquivo | Conteúdo | Uso recomendado |
|---|---|---|
| `logo-full.svg` | Background preto + P branco + pacote azul | Logo single-piece (favicon, README header, site, app store screenshots) |
| `logo-foreground.svg` | P + pacote em fundo transparente | iOS app icon (com background separado), Android adaptive icon foreground layer |
| `logo-background.svg` | Preto sólido 1024×1024 | Android adaptive icon background layer |
| `logo-monochrome.svg` | Silhueta branca completa (P + pacote unificados) | Android 13+ themed icon (o sistema colore conforme wallpaper) |
| `banner.svg` / `banner.png` | Banner 1280×640 — P à esquerda + nome + tagline + install + repo | Card de pacote pi.dev (`pi.image` no package.json), README hero do GitHub, social preview |

Todos os arquivos SVG do mark: **1024×1024** viewBox, safe zone Android-compatível.

## Como converter pra PNG

O render local usa [`@resvg/resvg-js`](https://www.npmjs.com/package/@resvg/resvg-js)
(Rust + WASM, sem deps nativas):

```bash
mkdir -p /tmp/rsvg && cd /tmp/rsvg && npm init -y && npm i @resvg/resvg-js
node -e "const {Resvg}=require('@resvg/resvg-js');const {readFileSync,writeFileSync}=require('fs');const d='branding/';for(const [s,p,w] of [['logo-full.svg','logo-full.png',1024],['banner.svg','banner.png',1280]]){const r=new Resvg(readFileSync(d+s,'utf8'),{fitTo:{mode:'width',value:w}}).render().asPng();writeFileSync(d+p,r);}console.log('ok')"
```

Alternativas: `rsvg-convert`, ImageMagick (`magick`), Inkscape, ou
Figma → export SVG/PNG.

## Tamanhos padrão pra exportar

| Plataforma | Tamanho | Arquivo fonte |
|---|---|---|
| iOS App Icon | 1024×1024 PNG (sem alpha) | `logo-full.svg` |
| Android Adaptive (foreground) | 432×432 PNG transparente | `logo-foreground.svg` |
| Android Adaptive (background) | 432×432 PNG (cor sólida) | `logo-background.svg` |
| Android Themed (monochrome) | 432×432 PNG transparente | `logo-monochrome.svg` |
| Favicon | 32×32, 16×16 PNG | `logo-full.svg` |
| App Store screenshot header | 1200×630 PNG | `logo-full.svg` (compor) |
| npm registry README | 512×512 PNG | `logo-full.svg` |

> Android adaptive icons: foreground e background ocupam 108dp de canvas total,
> mas conteúdo importante deve ficar dentro de 66dp central (safe zone). Os SVGs
> já respeitam essa proporção (~66% do 1024).

## Atualização

Mudanças visuais: editar o SVG. Regenerar PNGs derivados nos pontos de uso
(site `icon.svg`/`opengraph-image.tsx`, app, store). O mark também vive inline
em `site/src/app/opengraph-image.tsx` e `site/src/components/landing/icons.tsx`
(`LogoMark`) — manter esses inline copies em sincronia com `logo-full.svg`.

Antes de mudar paleta ou silhueta, atualizar este README com a nova versão da
identidade + razão.

## Histórico

- **2026-07-27** — mark trocado de **π** (era "Remote Pi") para o **P de Piper**
  (pipe-stem + pacote de dados), mantendo paleta e linguagem geométrica. Razão:
  o produto passou de "Remote Pi" para "Piper"; o π já não representava o nome.
