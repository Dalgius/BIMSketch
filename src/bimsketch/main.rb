# frozen_string_literal: true

require 'sketchup.rb'
require 'json'

module BIMSketch
  ROOT = File.dirname(__FILE__)

  %w[core/element_types core/quantities core/guid core/level_list core/step
     core/ifc_writer core/records core/wall_profile core/wall_joint core/wall_types core/opening_types
     model/settings model/levels model/bim_data model/wall_type_library model/geometry model/builder model/opening_sync model/collector
     tools/base_tool tools/linear_tools tools/opening_tool
     commands ui/dialogs].each { |f| require File.join(ROOT, f) }

  module_function

  # Pannello unico: schede Proprietà, Stratigrafie e Livelli.
  def panel
    @panel ||= Dialogs::Panel.new
  end

  def schedule_dialog
    @schedule_dialog ||= Dialogs::Schedule.new
  end

  def checker_dialog
    @checker_dialog ||= Dialogs::Checker.new
  end

  def select_tool(tool)
    Sketchup.active_model.select_tool(tool)
  end

  # Icone: SVG (vettoriali) su Windows, PNG 16/24 px su macOS.
  def icon(name, small = false)
    dir = File.join(ROOT, 'icons')
    svg = File.join(dir, "#{name}.svg")
    return svg if Sketchup.platform == :platform_win && File.exist?(svg)

    File.join(dir, small ? "#{name}_16.png" : "#{name}.png")
  end

  def command(label, icon_name, tooltip, &block)
    cmd = ::UI::Command.new(label) { block.call }
    if icon_name
      cmd.small_icon = icon(icon_name, true)
      cmd.large_icon = icon(icon_name)
    end
    cmd.tooltip = label
    cmd.status_bar_text = tooltip
    cmd
  end

  def commands
    @commands ||= {
      wall: command('Muro', 'wall', 'Disegna muri parametrici (clic iniziale e finale, a catena).') {
        select_tool(Tools::WallTool.new)
      },
      slab: command('Solaio', 'slab', 'Disegna un solaio cliccando i vertici del contorno.') {
        select_tool(Tools::SlabTool.new)
      },
      column: command('Pilastro', 'column', 'Posiziona pilastri rettangolari.') {
        select_tool(Tools::ColumnTool.new)
      },
      beam: command('Trave', 'beam', 'Disegna travi sotto il livello superiore.') {
        select_tool(Tools::BeamTool.new)
      },
      door: command('Porta', 'door', 'Inserisce una porta in un muro BIMSketch.') {
        select_tool(Tools::OpeningTool.new('door'))
      },
      window: command('Finestra', 'window', 'Inserisce una finestra in un muro BIMSketch.') {
        select_tool(Tools::OpeningTool.new('window'))
      },
      from_face: command('Elemento da faccia...', 'face',
                         'Crea solai, coperture, spazi o rivestimenti dalle facce selezionate.') {
        Commands.elements_from_faces
      },
      classify: command('Classifica selezione...', 'classify',
                        'Trasforma gruppi, componenti o geometria selezionati in elementi BIM.') {
        Commands.classify_selection
      },
      properties: command('Proprietà BIM', 'properties', 'Mostra e modifica le proprietà BIM.') {
        panel.show_tab('properties')
      },
      levels: command('Livelli', 'levels', 'Gestisce i livelli (piani) dell\'edificio.') {
        panel.show_tab('levels')
      },
      wall_types: command('Stratigrafie', 'layers', 'Stratigrafie di muri e solai: strati, materiali, spessori e trasmittanza U.') {
        panel.show_tab('types')
      },
      schedule: command('Abaco quantità', 'schedule', 'Abaco delle quantità degli elementi BIM.') {
        schedule_dialog.show
      },
      checker: command('Verifica modello', 'checker', 'Controlla la coerenza del modello BIM.') {
        checker_dialog.show
      },
      ifc: command('Esporta IFC...', 'ifc', 'Esporta il modello in formato IFC4.') {
        Commands.export_ifc
      },
      csv: command('Esporta abaco CSV...', nil, 'Esporta l\'abaco delle quantità in CSV.') {
        Commands.export_schedule_csv
      },
      settings: command('Impostazioni elementi...', 'settings',
                        'Dimensioni predefinite di muri, solai, pilastri, travi e aperture.') {
        Settings.edit
      },
      fix_guids: command('Correggi GlobalId duplicati', nil,
                         'Rigenera gli identificativi IFC duplicati dopo copia/incolla.') {
        Commands.fix_duplicate_guids
      },
      reverse_section: command('Inverti sezione attiva', nil,
                               'Inverte il verso del piano di sezione attivo.') {
        Commands.reverse_section
      },
      about: command('Informazioni su BIMSketch', nil, 'Versione e informazioni.') {
        Commands.about
      }
    }
  end

  def setup_menu
    c = commands
    menu = ::UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    model_menu = menu.add_submenu('Modellazione')
    %i[wall slab column beam door window from_face].each { |k| model_menu.add_item(c[k]) }
    menu.add_separator
    %i[properties levels wall_types classify].each { |k| menu.add_item(c[k]) }
    menu.add_separator
    %i[schedule checker ifc csv].each { |k| menu.add_item(c[k]) }
    menu.add_separator
    %i[settings fix_guids reverse_section about].each { |k| menu.add_item(c[k]) }
  end

  def setup_toolbar
    c = commands
    tb = ::UI::Toolbar.new(EXTENSION_NAME)
    %i[wall slab column beam door window from_face].each { |k| tb.add_item(c[k]) }
    tb.add_separator
    %i[properties levels wall_types classify].each { |k| tb.add_item(c[k]) }
    tb.add_separator
    %i[schedule checker ifc settings].each { |k| tb.add_item(c[k]) }
    tb.restore
  end

  def setup_context_menu
    ::UI.add_context_menu_handler do |menu|
      sel = Sketchup.active_model.selection
      next if sel.empty?

      sub = menu.add_submenu(EXTENSION_NAME)
      sub.add_item('Proprietà BIM') { panel.show_tab('properties') }
      classify = sub.add_submenu('Classifica come')
      ElementTypes.all.each do |t|
        classify.add_item("#{t.label} (#{t.ifc_class})") { Commands.classify_selection(t.key) }
      end
      if sel.any? { |e| BimData.element?(e) }
        assign = sub.add_submenu('Assegna al livello')
        Levels.all.each do |l|
          assign.add_item(l['name']) { Commands.assign_selection_to_level(l['id']) }
        end
        sub.add_item('Rimuovi classificazione BIM') { Commands.declassify_selection }
      end
      sub.add_item('Elemento da faccia...') { Commands.elements_from_faces } if sel.any? { |e| e.is_a?(Sketchup::Face) }
    end
  end

  unless file_loaded?(__FILE__)
    OpeningSync.install
    setup_menu
    setup_toolbar
    setup_context_menu
    file_loaded(__FILE__)
  end
end
