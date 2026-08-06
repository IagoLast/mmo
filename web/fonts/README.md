# Fuentes del lanzador web

Se sirven desde el repo a propósito: la página se abre desde un móvil por la LAN,
a veces sin salida a internet, así que un `<link>` a `fonts.googleapis.com` la
rompería justo donde más se usa. `web/build-web.sh` copia este directorio entero
a `web/dist/fonts/`.

| Fichero | Familia | Origen | Licencia |
| --- | --- | --- | --- |
| `press-start-2p-latin.woff2` | Press Start 2P 400 | Google Fonts, subconjunto `latin` (v16) | OFL 1.1 — `press-start-2p-OFL.txt` |
| `silkscreen-latin-400.woff2` | Silkscreen 400 | Google Fonts, subconjunto `latin` (v6) | OFL 1.1 — `silkscreen-OFL.txt` |
| `silkscreen-latin-700.woff2` | Silkscreen 700 | Google Fonts, subconjunto `latin` (v6) | OFL 1.1 — `silkscreen-OFL.txt` |

Solo el subconjunto `latin` (U+0000–00FF y compañía), que cubre los acentos y la
`ñ` del castellano; las variantes cirílica, griega y latin-ext no se descargan
porque la página no las usa. Total: ~11 kB.

Para actualizarlas, pide el CSS de Google Fonts con un User-Agent moderno
(`https://fonts.googleapis.com/css2?family=Press+Start+2P&family=Silkscreen:wght@400;700`),
quédate con los bloques cuyo `unicode-range` empieza en `U+0000-00FF`, y baja
esos `.woff2`.

La OFL permite redistribuir el binario siempre que viaje con su licencia: no
borres los `*-OFL.txt` de este directorio.
