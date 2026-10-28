# BIMSketch

**Estensione per SketchUp che trasforma l'applicazione in uno strumento BIM.**

BIMSketch aggiunge a SketchUp elementi edilizi parametrici, classificazione IFC,
livelli di piano, proprietà e Property Set, abachi delle quantità, verifica del
modello ed esportazione in **IFC4** (validato con IfcOpenShell). Le geometrie
restano normali gruppi SketchUp, quindi si possono ancora modificare con gli
strumenti nativi (Spingi/Tira, Sposta, Scala…); le quantità vengono ricalcolate
dalla geometria reale.

## Funzionalità

| Area | Cosa fa |
|---|---|
| **Modellazione BIM** | Strumenti **Muro** (a catena, con aggancio ai muri esistenti, giunti d'angolo a quartabuono e giunti a T con qualunque angolo, allineamento asse/sinistra/destra, lunghezza da tastiera), **Solaio** (contorno a clic, oppure **dai muri** selezionati, con **fori** rettangolari), **Pilastro**, **Trave**, **Scala** rettilinea (alzate e pedate calcolate, vano nel solaio automatico), **Porta** e **Finestra** (tagliano il foro passante nel muro e creano l'elemento nel vano; tipologie a battente, a due ante, scorrevole, portafinestra, vasistas e fissa, con telaio, ante e vetri; tasto destro per scegliere la tipologia, cambiabile anche dopo dal pannello Proprietà; spostamento lungo il muro con lo Sposta di SketchUp o con la posizione numerica) |
| **Stratigrafie** | Librerie di tipologie di muro e di solaio/copertura (strati con materiale, spessore, conduttività λ e funzione); strati visibili come solidi colorati, con aperture e giunti nei muri, finiture che risvoltano nei vani delle aperture; nei solai gli strati vanno dall'estradosso all'intradosso e la faccia superiore resta alla quota del livello; trasmittanza U secondo UNI EN ISO 6946 (flusso orizzontale, verso il basso o verso l'alto) scritta nel Pset; computo dei materiali; IfcMaterialLayerSet nell'IFC |
| **Elemento da faccia** | Crea solai, coperture, fondazioni, rivestimenti o **spazi (locali)** estrudendo le facce selezionate, anche inclinate e con fori |
| **Classificazione** | Trasforma gruppi, componenti o geometria esistenti in elementi BIM: 14 categorie IFC (IfcWall, IfcSlab, IfcColumn, IfcBeam, IfcDoor, IfcWindow, IfcRoof, IfcStair, IfcRailing, IfcCovering, IfcFooting, IfcFurniture, IfcSpace, IfcBuildingElementProxy) con tipo predefinito, tag SketchUp e materiale di categoria. Se nel modello è caricato uno schema IFC applica anche la classificazione nativa di SketchUp |
| **Pannello BIMSketch** | Un unico pannello con le schede **Proprietà**, **Stratigrafie** e **Livelli**, intestazione con la selezione corrente e azioni sempre visibili in basso (più collegamenti ad Abaco, Verifica ed Esporta IFC). La scheda Proprietà segue la selezione: categoria, tipo predefinito, nome, tipologia (ObjectType), livello, materiale, GlobalId, altezza di muri e pilastri (numerica o automatica dal livello), **Pset standard** (Pset_WallCommon, Pset_DoorCommon, …: portante, esterno, REI, trasmittanza U, ecc.), proprietà personalizzate e quantità calcolate. Modifica multipla su più elementi |
| **Livelli** | Piani dell'edificio (IfcBuildingStorey) con quota e altezza; livello corrente per gli strumenti; seleziona/isola/assegna elementi; cambiando la quota gli elementi del piano si spostano, cambiando l'altezza muri e pilastri automatici si adeguano e le travi restano sotto il piano superiore; **vista in pianta** automatica (piano di sezione + scena) |
| **Abaco quantità** | Tabella filtrabile di tutti gli elementi con lunghezze, spessori, altezze, superfici e volumi, riepilogo per categoria, selezione nel modello, **esportazione CSV** per Excel (separatore `;`, virgola decimale) |
| **Quantità IFC** | Qto_*BaseQuantities calcolate dalla geometria: lunghezza, spessore, altezza, impronta, superficie laterale lorda/netta (al netto delle aperture), superfici, perimetro, volume lordo/netto |
| **Verifica modello** | GlobalId duplicati (es. dopo copia/incolla) con correzione automatica, elementi senza livello, elementi strutturali non solidi, aperture senza muro ospite, elementi senza materiale, oggetti non classificati, facce sciolte |
| **Esportazione IFC4** | Progetto → Sito (con georeferenziazione) → Edificio → Piani; elementi con geometria triangolata (IfcTriangulatedFaceSet), colori, materiali, Pset, Qto e proprietà personalizzate; opzionalmente oggetti non classificati come IfcBuildingElementProxy. File apribili in BIMvision, Solibri, Revit, ArchiCAD, BlenderBIM/Bonsai, usBIM, ecc. |

## Requisiti

- SketchUp desktop **2019 o successivo** (Windows o macOS). Non servono le funzioni di
  SketchUp Pro: l'esportazione IFC è realizzata dall'estensione stessa.

## Installazione

1. Scarica il file `.rbz` dell'ultima versione dalla pagina
   [Releases](https://github.com/Dalgius/BIMSketch/releases) (oppure crealo con `rake build`, vedi sotto).
2. In SketchUp: **Estensioni → Extension Manager → Installa estensione…** e scegli il file `.rbz`.
3. Compaiono il menu **Estensioni → BIMSketch** e la barra strumenti **BIMSketch**
   (se non è visibile: *Visualizza → Barre degli strumenti → BIMSketch*).

In alternativa copia `src/bimsketch.rb` e la cartella `src/bimsketch/` nella cartella
Plugins di SketchUp.

## Guida rapida

1. **Livelli** – apri *Livelli*, imposta quote e altezze dei piani (es. Piano Terra 0,00 m,
   Piano Primo 3,20 m) e scegli il livello corrente (●).
2. **Impostazioni** – *Impostazioni elementi…* (o tasto destro durante uno strumento) per
   spessore muri, dimensioni di pilastri, travi, porte e finestre.
3. **Muri** – strumento *Muro*: clic sul punto iniziale e sui successivi; digita una lunghezza
   per fissarla; doppio clic, Invio o Esc per terminare. Shift blocca la direzione.
4. **Porte e finestre** – passa sopra un muro creato con BIMSketch e clicca: il foro viene
   tagliato attraverso il muro e l'elemento viene inserito e collegato al muro ospite.
5. **Solai** – strumento *Solaio* (contorno a clic, estradosso alla quota del livello) oppure
   seleziona facce e usa *Elemento da faccia…*. Con lo stesso comando crei gli **spazi**.
6. **Modelli esistenti** – seleziona gruppi/componenti/geometria e usa *Classifica selezione…*
   o il menu contestuale *BIMSketch → Classifica come*.
7. **Proprietà** – apri *Proprietà BIM* e compila Pset, materiale e tipologia.
8. **Controllo** – *Verifica modello*, poi *Abaco quantità* e infine *Esporta IFC…*.

## Come sono salvati i dati

- Ogni elemento è un gruppo (o componente) con il dizionario di attributi `BIMSketch`
  (`type`, `guid`, `level`, `predefined`, `object_type`, `material`, `host`, `props`, `custom`):
  i dati viaggiano dentro il file `.skp`.
- I livelli sono salvati negli attributi del modello (`BIMSketch_Levels`).
- Gli elementi creati dagli strumenti hanno un sistema locale coerente
  (x = asse dell'elemento, y = spessore, z = altezza) su cui si basano le quantità.
- Ogni categoria ha il suo tag SketchUp (`BIM - Muri`, `BIM - Solai`, …) per gestire la
  visibilità.

## Struttura del codice

```
src/
├── bimsketch.rb              # loader dell'estensione (SketchupExtension)
└── bimsketch/
    ├── main.rb               # menu, barra strumenti, menu contestuale
    ├── commands.rb           # comandi: classifica, elemento da faccia, esportazioni…
    ├── core/                 # Ruby puro, testato senza SketchUp
    │   ├── element_types.rb  # catalogo categorie IFC, Pset e Qto
    │   ├── quantities.rb     # calcolo quantità da misure geometriche
    │   ├── ifc_writer.rb     # scrittore IFC4 (STEP)
    │   ├── step.rb, guid.rb  # codifica STEP e GlobalId IFC
    │   ├── level_list.rb     # logica dei livelli
    │   └── records.rb        # mappatura IFC, abaco/CSV, verifica modello
    ├── model/                # integrazione con l'API SketchUp
    │   ├── bim_data.rb       # attributi BIM sulle entità
    │   ├── levels.rb         # livelli, isolamento, viste in pianta
    │   ├── builder.rb        # creazione elementi parametrici
    │   ├── geometry.rb       # estrusioni, taglio aperture
    │   ├── collector.rb      # raccolta elementi, misure e mesh
    │   └── settings.rb       # impostazioni utente
    ├── tools/                # strumenti interattivi (Muro, Solaio, …)
    ├── ui/                   # pannello unico (Proprietà, Stratigrafie, Livelli), Abaco, Verifica
    └── icons/                # icone SVG (Windows) e PNG (macOS)
```

## Sviluppo

```bash
gem install minitest rake
rake test     # test del nucleo, del writer IFC e caricamento dell'estensione
rake build    # crea dist/bimsketch-<versione>.rbz
```

I test validano la struttura del file IFC (riferimenti, numero di attributi di ogni
entità IFC4). Per una validazione completa dello schema:

```bash
pip install ifcopenshell pytest
python -m ifcopenshell.validate --rules modello.ifc
```

### Autotest dentro SketchUp

`tools/autotest.rb` prova le funzioni principali dentro un vero SketchUp (muri, giunti,
taglio di porte e finestre, solidità e volumi, livelli, proprietà, abaco, IFC, strumenti).
Con BIMSketch installata apri un modello vuoto, poi nella Ruby Console:

```ruby
load "C:/percorso/autotest.rb"
```

Il resoconto ✓/✗ viene stampato nella console.

### Pubblicare una nuova versione

1. Aggiorna `VERSION` in `src/bimsketch/version.rb` (es. `1.1.0`).
2. Facoltativo: scrivi le note di rilascio in `release-notes/v1.1.0.md`
   (se il file manca, GitHub le genera dai commit).
3. Dopo il merge su `main`, crea e invia il tag:
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
Il workflow `Release` esegue i test, compila il `.rbz` e pubblica la release con il
pacchetto allegato. Se il tag non corrisponde alla versione, il workflow si ferma.

In alternativa, anche da smartphone, si può creare la release dal sito di GitHub
(*Releases → Draft a new release*, nuovo tag `v1.1.0` su `main`, titolo e note,
*Publish release*): il workflow parte con il nuovo tag e allega il `.rbz` alla
release dopo un paio di minuti.

Le icone PNG si rigenerano dalle SVG con
`NODE_PATH=$(npm root -g) node tools/render_icons.js` (richiede Playwright).

## Limiti noti

- Porte e finestre si inseriscono nei muri creati con lo strumento *Muro* (muri rettilinei);
  per altri oggetti usa la classificazione.
- La geometria IFC è esportata come superficie triangolata (non parametrica); le aperture
  sono già ritagliate nella geometria del muro e non sono esportate come IfcOpeningElement.
- I giunti d'angolo tra muri sono a quartabuono; nei giunti a T il muro secondario si ferma sulla faccia
  del muro principale (gli strati non si compenetrano).

## Licenza

MIT – vedi [LICENSE](LICENSE).
