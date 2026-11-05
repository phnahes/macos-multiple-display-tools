# monitor-tools

Controle o brilho de um monitor externo no macOS — e faça ele acompanhar o brilho
do display do Mac — com um app na barra de menu e uma CLI. O app também mostra o
ângulo de abertura da tampa do MacBook.

Feito porque o macOS não expõe controle de brilho para monitores de terceiros, e
o F1/F2 só funciona no display integrado (ou em telas da Apple).

```
monitor-tools
├── MonitorBar.app   app de barra de menu que sincroniza o brilho
└── monitor / brilho / contraste / monitor-info   CLI via DDC/CI
```

## Como funciona

- **Brilho do monitor externo:** [DDC/CI](https://en.wikipedia.org/wiki/Display_Data_Channel)
  pelo [m1ddc](https://github.com/waydabber/m1ddc), que usa `IOAVService` em Apple Silicon.
  É o backlight de verdade, não uma película escura por software.
- **Brilho do display integrado:** API privada `DisplayServicesGetBrightness` /
  `DisplayServicesSetBrightness` (`/System/Library/PrivateFrameworks/DisplayServices.framework`),
  a mesma que o Control Center usa. Carregada com `dlopen`, sem entitlements.
- **Porta física:** lida do `ioreg` (`IOPortTransportStateDisplayPort`) e mapeada
  para a posição real da porta (`port-location` dos nós `hpm`).
- **Ângulo da tampa:** sensor Hall do hinge, exposto como HID (`usage page 0x20`,
  `usage 0x8A`, feature report 1). Os dois primeiros bytes são o ângulo em graus.

## Requisitos

- Apple Silicon (foi feito e testado em M4; deve funcionar em M1/M2/M3)
- macOS 12+
- [m1ddc](https://github.com/waydabber/m1ddc): `brew install m1ddc`
- Swift/Command Line Tools para compilar o app: `xcode-select --install`
- Monitor que aceite DDC/CI (a maioria dos monitores de mesa aceita; monitores
  portáteis baratos às vezes ignoram)

## Instalação

```bash
git clone <este-repo> monitor-tools
cd monitor-tools
./install.sh
```

O `install.sh`:

1. cria symlinks em `~/.local/bin` (`monitor`, `brilho`, `contraste`, `monitor-info`);
2. compila e instala o `MonitorBar.app` em `~/Applications`;
3. registra um LaunchAgent (`com.paulonahes.monitorbar`) para abrir no login.

Se `~/.local/bin` não estiver no `PATH`, o script avisa. Para desinstalar:

```bash
./uninstall.sh
```

## CLI

```bash
brilho                 # imprime o brilho atual (0-100)
brilho 60              # define 60%
brilho +10             # aumenta 10 pontos
brilho -10             # diminui 10 pontos
brilho max             # 100

contraste 75
monitor volume 40
monitor info           # displays, porta física, link e valores atuais
monitor list           # displays vistos pelo m1ddc
```

Exemplo de `monitor info`:

```
Displays:
  [1] Unknown Display (37D8832A-...)
  [2] ARZOPA (7EC3C4DC-...)

Monitor:  ARZOPA
Conexão: USB-C 2 (esquerda, traseira)
Link:    2.7 Gbps (HBR), 4 lanes

Brilho: 100
Contraste: 50
Volume: 50
```

Os comandos imprimem só o número, então dá para usar em script:

```bash
if [ "$(brilho)" -lt 30 ]; then brilho 30; fi
```

### Variáveis de ambiente

| Variável | Padrão | Para quê |
|---|---|---|
| `MONITOR_NAME` | `ARZOPA` | trecho do nome do display na lista do m1ddc |
| `MONITOR_ID` | — | índice fixo do display; ignora o nome |
| `M1DDC_BIN` | `m1ddc` no PATH | caminho do binário |
| `MONITORBAR_DEBUG` | — | `1` faz o app logar brilho e ângulo no stderr |

## MonitorBar (barra de menu)

Ícone de sol na barra. O menu tem:

- **Brilho do Mac: X%** — valor atual do display integrado
- **slider** — com a sincronização ligada, move o brilho do Mac (e o externo
  acompanha); desligada, controla direto o externo
- **Seguir o brilho do Mac** — liga/desliga a sincronização (fica salvo)
- **Sincronizar agora** — força uma sincronização
- **Monitor: ARZOPA (2)** — display em uso
- **Tampa: 112°** — ângulo de abertura da tampa, em tempo real
- **Mostrar ângulo na barra** — exibe o ângulo ao lado do ícone (fica salvo)

Com a sincronização ligada, **F1/F2 e o Control Center passam a controlar os dois
monitores ao mesmo tempo**, inclusive as mudanças automáticas do sensor de luz
ambiente. É só usar o Mac normalmente.

Detalhes da implementação:

- lê o brilho interno a cada 0,4 s;
- espera 150 ms de estabilidade antes de escrever (uma rampa de F1/F2 muda o valor
  várias vezes por segundo, e um write por passo satura o barramento DDC);
- só escreve quando a diferença é ≥ 1%;
- lê o ângulo da tampa no mesmo intervalo, direto do feature report do sensor.

O ângulo aparece como `Tampa: 112°` no menu. Se o modelo não tiver o sensor (Mac
mini, Studio, iMac), o item mostra "sensor indisponível" e o resto continua
funcionando.

### Atalhos de teclado

Não é necessário, mas se quiser teclas próprias para o externo:

```bash
# skhd (~/.config/skhd/skhdrc)
cmd + alt - down : brilho -10
cmd + alt - up   : brilho +10
```

No Raycast/Karabiner, use os mesmos comandos.

## Descobrindo a porta do monitor

O macOS não mostra isso em lugar nenhum. A CLI lê do `ioreg`:

```bash
ioreg -r -c IOPortTransportStateDisplayPort -l | grep -E "TransportDescription|Active|LinkRate"
```

Saída no MacBook Pro 14" (a numeração interna não segue a ordem visual):

```
"TransportDescription" = "Port-HDMI@3/DisplayPort"      "Active" = No
"TransportDescription" = "Port-USB-C@2/DisplayPort"     "Active" = Yes   2.7 Gbps (HBR)
```

O `port-label` cruza `Port-USB-C@N` com o `port-location` do nó `hpmN`:

| Porta | `port-location` | `port-number` |
|---|---|---|
| USB-C 1 | `left-front` | 1 |
| USB-C 2 | `left-rear` | 2 |
| USB-C 4 | `right` | 4 |

Isso é específico de MacBook; em Mac mini/Studio o mapa pode não existir e a CLI
mostra apenas `USB-C N`.

## Limitações

- O monitor precisa suportar DDC/CI. Se `brilho` falhar, teste `contraste`:
  alguns monitores respondem a um e não ao outro.
- Hubs e docks USB-C às vezes bloqueiam DDC. Cabo direto é mais confiável.
- `DisplayServices` é API privada: pode quebrar em atualizações do macOS. Se o
  menu mostrar "Brilho do Mac: indisponível", é isso que aconteceu.
- Com a sincronização ligada, mudanças feitas pela CLI (`brilho 80`) são
  sobrescritas na próxima mudança do brilho do Mac. Para controle independente,
  desligue "Seguir o brilho do Mac" no menu.
- O auto-brilho do macOS (sensor de luz) fica ativo e gera pequenos ajustes; a
  sincronização os reproduz no externo.
- O ângulo da tampa só existe em MacBook com o sensor (M1 em diante; alguns Intel
  de 2019/2020 também). Não há API pública: é HID não documentado, então pode
  mudar em modelos futuros.

## Solução de problemas

**`monitor: nenhum display chamado "ARZOPA"`**
Rode `monitor list` e ajuste `MONITOR_NAME`, ou passe o índice:
`MONITOR_ID=2 brilho 50`.

**O display some da lista do m1ddc**
Desconecte e reconecte o cabo. O índice pode mudar — o MonitorBar re-resolve
sozinho a cada 5 s.

**DDC não responde**
Teste com o cabo direto na porta USB-C/HDMI do Mac, sem hub. Confirme que o
monitor aceita DDC (alguns exigem habilitar no OSD).

**O ícone não aparece na barra**
`pgrep -fl MonitorBar` para ver se está rodando e
`launchctl print gui/$(id -u)/com.paulonahes.monitorbar` para o estado do agente.
Logs em `~/Library/Logs/MonitorBar.log`.

## Testado em

- MacBook Pro 14" (Mac16,1, Apple M4), macOS 26.6.2
- ARZOPA 16" (2560x1600, EDID `GWD`), USB-C → DisplayPort Alt Mode, 4 lanes HBR
- Ângulo da tampa: sensor HID presente, leitura estável em graus inteiros (0-180)

Funciona em outros monitores; o nome no `MONITOR_NAME` é o que muda.

## Estrutura

```
bin/monitor      CLI (um script, quatro nomes)
app/main.swift   app de barra de menu
app/Info.plist   bundle (LSUIElement)
app/build.sh     compila com swiftc, sem Xcode
install.sh       CLI + app + LaunchAgent
uninstall.sh     remove tudo
```

## Licença

MIT.
