# Speedtest Meter — plugin Noctalia v5

Widget na barra + painel com velocímetro e tela final de dados técnicos completos.

## Funciona independente da distro (dois backends)

O painel detecta, nessa ordem, qual ferramenta de speedtest existe no sistema:

1. **`speedtest`** (Ookla CLI oficial) — dá progresso linha a linha em JSON, então o velocímetro
   é 100% em tempo real (ping → download → upload). Em Arch normalmente vem via AUR
   (ex.: `yay -S speedtest-bin`, `ookla-speedtest-bin` ou `ookla-speedtest-cli-bin` — os nomes
   mudaram algumas vezes no AUR, vale conferir com `yay -Ss speedtest` qual está disponível hoje).
2. **`speedtest-cli`** (Python, pacote `speedtest-cli`) — está nos repositórios oficiais da
   maioria das distros, inclusive **Arch** (`sudo pacman -S speedtest-cli`, sem precisar de AUR).
   Essa ferramenta não expõe progresso incremental, então nesse modo o velocímetro pulsa (efeito
   "carregando") em vez de mostrar Mbps ao vivo — o resultado final continua completo.

Se nenhum dos dois existir, a tela de erro detecta seu gerenciador de pacotes
(pacman/apt/dnf/zypper/apk) e mostra o comando de instalação certo — no seu caso, Arch, isso é
`sudo pacman -S speedtest-cli`.

## Ícone do widget

Confirmado e implementado com o schema real que você mandou: `[[widget.setting]]` aninhado dentro
de `[[widget]]` no `plugin.toml` (`type = "glyph"`, `label_key`/`description_key` apontando pras
traduções, `default = "wifi"`), lido em `widget.luau` via `noctalia.getConfig("glyph")` e
renderizado com `ui.glyph` + `barWidget.render` (em vez do `setText` fixo de antes) — igual ao
padrão do seu `rss-notifier`. Deve aparecer agora na tela de configurações do widget na barra.

## Painel travava depois de fechar durante o teste

Bug real, corrigido: ao fechar o painel, o código descartava o resultado do teste em vez de só
pausar a atualização visual — `if not panelActive then return end` no início dos callbacks de
progresso/resultado (`onSpeedtestLine`, o callback do backend legado, `fetchClientInfo`) fazia o
teste terminar "no vácuo" se o painel estivesse fechado naquele momento. Reabrir o painel depois
mostrava a tela congelada pra sempre, porque aquele callback já tinha rodado e descartado tudo.

Agora esses callbacks sempre processam o resultado (atualizam `result`/`state` normalmente),
independente do painel estar aberto ou fechado — só a chamada de `panel.render()` é pulada
enquanto fechado (isso já era seguro, é só não desenhar). Reabrir o painel mostra o estado real
(rodando, com o cronômetro retomado, ou já concluído, se tiver terminado enquanto estava fechado).

## Velocímetro não aparecia durante o teste

`ui.progress({ value, orientation = "circular", thickness = 10 })` não desenhava nada — os props
`orientation`/`thickness` eram chute e claramente não existem (ou têm outro nome/valor) no seu
Noctalia. Troquei por três camadas de feedback visual durante o teste:

1. `ui.progress({ value = ... })` — só o prop que com certeza existe (0..1). Se seu `ui.progress`
   aceitar outros props pra deixá-lo mais bonito (cor, espessura, formato circular), me diga quais
   são que eu ajusto.
2. Uma barra de texto (`████░░░░`) — não depende de nenhum prop desconhecido, é só `ui.label`,
   então funciona garantido.
3. Um cronômetro (mm:ss) do tempo decorrido — outra confirmação de que está rodando, mesmo se as
   duas barras acima não aparecerem por algum motivo.

## Detecção de backend corrigida — causa raiz confirmada

No Arch, o pacote oficial `speedtest-cli` instala **dois** binários: `speedtest-cli` e também
`speedtest` (ambos são o mesmo script Python, com nomes diferentes). Antes, o plugin via
`speedtest` no PATH e concluía "é o CLI oficial da Ookla" — mas nesse caso é o Python, que não
entende as flags `--format=json --progress=yes`, então não produzia nada útil e o velocímetro
ficava travado em "Preparando...".

Agora, antes de confiar em `speedtest`, o plugin roda `speedtest --version` e só usa o backend
"ookla" (streaming ao vivo) se a saída mencionar "Ookla". Caso contrário — como no seu caso —, cai
automaticamente pro backend "legacy" via `speedtest-cli` (que você confirmou funcionar 100% no
terminal), com o velocímetro em modo "pulso" (sem progresso incremental, mas resultado final
completo).

## Pontos que você deve conferir/ajustar

O `.txt` que você me passou documenta a API Luau em runtime (`noctalia.*`, `ui.*`, `panel.*`,
callbacks de entrada), mas **não** documenta:

- **O schema do `plugin.toml`** — escrevi por convenção; compare com o `plugin.toml` do seu
  `link-ip-monitor` (que já funciona) se algo não carregar.
- **As props exatas de `ui.progress`** (se `orientation = "circular"` existe mesmo) e de
  `ui.input` (`value`/`placeholder`/`onChange`) — são melhores palpites, comentados no código.
  Se `ui.input` não aceitar `onChange`, o campo de ícone pode precisar de ajuste.

## Arquivos

- `plugin.toml` — manifesto do plugin.
- `widget.luau` — widget da barra (ícone configurável + abre o painel).
- `panel.luau` — toda a lógica: detecção de backend/distro, streaming ou execução do teste,
  normalização do resultado, persistência do último resultado, geolocalização extra do cliente,
  e o campo de ícone do widget.
- `translations/en.json`, `translations/pt-BR.json` — strings de interface.
