# frozen_string_literal: true

module BIMSketch
  # Comandi non interattivi del menu BIMSketch.
  module Commands
    YES = 'Sì'
    NO = 'No'

    module_function

    def model
      Sketchup.active_model
    end

    def operation(name)
      model.start_operation(name, true)
      result = yield
      model.commit_operation
      result
    rescue StandardError => e
      model.abort_operation
      UI.messagebox("BIMSketch: #{e.message}")
      puts e.backtrace.join("\n")
      nil
    end

    def level_names(m = model)
      Levels.all(m).map { |l| l['name'] }
    end

    def level_by_name(m, name)
      Levels.all(m).find { |l| l['name'] == name }
    end

    # Classifica la selezione: gruppi/componenti selezionati diventano
    # elementi BIM; facce e spigoli sciolti vengono prima raggruppati.
    def classify_selection(type_key = nil)
      sel = model.selection
      if sel.empty?
        UI.messagebox('Seleziona gruppi, componenti o geometria da classificare.')
        return
      end
      auto = 'Automatico (dalla quota)'
      level = nil
      name = ''
      if type_key.nil?
        input = UI.inputbox(['Tipo elemento', 'Livello', 'Nome (opzionale)'],
                            [ElementTypes['wall'].label, auto, ''],
                            [ElementTypes.labels.join('|'), ([auto] + level_names).join('|'), ''],
                            'BIMSketch - Classifica selezione')
        return unless input

        type_key = ElementTypes.key_for_label(input[0]) || 'proxy'
        level = input[1] == auto ? nil : level_by_name(model, input[1])
        name = input[2].to_s.strip
      end
      operation('BIMSketch: Classifica') do
        targets = sel.select { |e| BimData.instance?(e) }
        loose = sel.select { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge) }
        targets << model.active_entities.add_group(loose) unless loose.empty?
        targets.each_with_index do |e, i|
          n = name.to_s.empty? ? nil : (targets.size > 1 ? "#{name} #{i + 1}" : name)
          BimData.classify(e, type_key, level: level && level['id'], name: n)
        end
        sel.clear
        sel.add(targets)
        targets.size
      end
    end

    def declassify_selection
      items = model.selection.select { |e| BimData.element?(e) }
      return if items.empty?

      operation('BIMSketch: Rimuovi classificazione') { items.each { |e| BimData.declassify(e) } }
    end

    # Crea elementi (solaio, copertura, spazio, rivestimento, fondazione)
    # estrudendo le facce selezionate lungo la loro normale.
    FACE_TYPES = {
      'Solaio' => ['slab', :down, 'slab_thickness'],
      'Copertura' => ['roof', :down, 'slab_thickness'],
      'Fondazione' => ['footing', :down, 'slab_thickness'],
      'Rivestimento / pavimento' => ['covering', :up, nil],
      'Spazio (locale)' => ['space', :up, nil]
    }.freeze

    # Solaio dal perimetro dei muri selezionati (filo esterno, estradosso in
    # testa ai muri); i muri con altezza automatica si fermano sotto il solaio.
    def slab_from_walls
      walls = model.selection.select { |e| Builder.parametric_wall?(e) }
      if walls.size < 3
        UI.messagebox('Seleziona i muri BIMSketch del perimetro (almeno tre, raccordati agli angoli).')
        return
      end
      none = '(nessuna: spessore libero)'
      types = WallTypeLibrary.all(model, kind: 'slab')
      current = Settings.slab_type(model)
      input = UI.inputbox(['Tipologia del solaio', 'Spessore senza tipologia (mm)', 'Muri sotto il solaio'],
                          [current ? current['name'] : none, Settings.get('slab_thickness').to_s, YES],
                          [([none] + types.map { |t| t['name'] }).join('|'), '', "#{YES}|#{NO}"],
                          'BIMSketch - Solaio dai muri')
      return unless input

      type = types.find { |t| t['name'] == input[0] }
      thickness = input[1].to_s.tr(',', '.').to_f
      thickness = Settings.get('slab_thickness').to_f if thickness <= 0
      result = operation('BIMSketch: Solaio dai muri') do
        Builder.slab_from_walls(model, walls, thickness.mm, type_id: type && type['id'], stop_walls: input[2] == YES)
      end
      return unless result

      if result[:error]
        UI.messagebox(result[:error])
        return
      end
      model.selection.clear
      model.selection.add(result[:slab])
      return unless result[:failed].positive?

      UI.messagebox("#{result[:failed]} muri non sono stati abbassati sotto il solaio: sono stati modificati a mano " \
                    'oppure le loro aperture non entrerebbero.')
    end

    def elements_from_faces
      faces = model.selection.grep(Sketchup::Face)
      if faces.empty?
        UI.messagebox('Seleziona una o più facce (es. il contorno di un locale o di un solaio).')
        return
      end
      input = UI.inputbox(['Tipo elemento', 'Spessore/altezza (mm, 0 = predefinito)',
                           'Elimina le facce originali'],
                          ['Solaio', '0', YES],
                          [FACE_TYPES.keys.join('|'), '', "#{YES}|#{NO}"],
                          'BIMSketch - Elemento da faccia')
      return unless input

      key, direction, setting = FACE_TYPES[input[0]]
      value = input[1].to_s.tr(',', '.').to_f
      thickness = if value > 0
                    value.mm
                  elsif setting
                    Settings.length(setting)
                  elsif key == 'covering'
                    20.mm
                  else
                    Levels.current_height(model)
                  end
      erase = input[2] == YES
      operation('BIMSketch: Elemento da faccia') do
        created = faces.map { |f| element_from_face(f, key, direction, thickness) }.compact
        if erase
          edges = faces.flat_map(&:edges).uniq
          model.active_entities.erase_entities(faces)
          orphans = edges.select { |e| e.valid? && e.faces.empty? }
          model.active_entities.erase_entities(orphans) unless orphans.empty?
        end
        model.selection.clear
        model.selection.add(created)
        created.size
      end
    end

    def element_from_face(face, key, direction, thickness)
      normal = face.normal
      normal = normal.reverse if normal.z < -1e-6
      first = face.outer_loop.vertices.map(&:position)
      return nil if first.size < 3

      # Sistema locale della faccia: z = normale, x = primo spigolo.
      xaxis = first[1] - first[0]
      xaxis.normalize!
      yaxis = normal * xaxis
      base = Geom::Transformation.axes(first[0], xaxis, yaxis, normal)
      inv = base.inverse
      outer = first.map { |p| flat(p.transform(inv)) }
      holes = face.loops.reject(&:outer?).map { |l| l.vertices.map { |v| flat(v.position.transform(inv)) } }
      origin_offset = direction == :down ? -thickness : 0
      tr = base * Geom::Transformation.translation([0, 0, origin_offset])
      tr = model.edit_transform * tr if model.active_path
      group = Geometry.create_group(model, tr) do |ents|
        Geometry.prism(ents, outer, holes, thickness)
      end
      BimData.classify(group, key)
      group
    end

    def flat(p)
      Geom::Point3d.new(p.x, p.y, 0)
    end

    # Rigenera i GlobalId duplicati (es. dopo copia/incolla di elementi).
    def fix_duplicate_guids(m = model, silent: false)
      seen = {}
      fixed = 0
      m.start_operation('BIMSketch: Correggi GlobalId', true)
      Collector.each_element(m) do |e, _|
        g = BimData.guid(e)
        if !Guid.valid?(g.to_s) || seen[g]
          g = BimData.regenerate_guid(e)
          fixed += 1
        end
        seen[g] = true
      end
      m.commit_operation
      UI.messagebox("GlobalId corretti: #{fixed}") unless silent
      fixed
    end

    # Assegna il livello in base alla quota agli elementi che non ne hanno uno valido.
    def assign_missing_levels(m = model)
      levels = Levels.all(m)
      ids = levels.map { |l| l['id'] }
      count = 0
      m.start_operation('BIMSketch: Assegna livelli', true)
      Collector.each_element(m) do |e, world|
        next if ids.include?(BimData.level_id(e))

        z = e.definition.bounds.min.transform(world).z.to_m
        e.set_attribute(BimData::DICT, 'level', LevelList.for_z(levels, z)['id'])
        count += 1
      end
      m.commit_operation
      count
    end

    def assign_selection_to_level(level_id)
      items = model.selection.select { |e| BimData.element?(e) }
      return 0 if items.empty?

      operation('BIMSketch: Assegna livello') do
        Levels.relocate(model, items, level_id)
        items.size
      end
    end

    def export_ifc
      m = model
      title = m.title.to_s.empty? ? 'modello' : m.title
      input = UI.inputbox(['Nome progetto', 'Nome edificio', 'Autore',
                           'Esporta oggetti non classificati (come elementi generici)'],
                          [title, 'Edificio', ENV['USERNAME'] || ENV['USER'] || '', NO],
                          ['', '', '', "#{YES}|#{NO}"], 'BIMSketch - Esporta IFC4')
      return unless input

      dir = m.path.to_s.empty? ? nil : File.dirname(m.path)
      path = UI.savepanel('Esporta IFC', dir, "#{title}.ifc")
      return unless path

      path += '.ifc' unless path.downcase.end_with?('.ifc')
      fix_duplicate_guids(m, silent: true)
      Sketchup.status_text = 'BIMSketch: esportazione IFC in corso...'
      records = Collector.collect(m, mesh: true, proxies: input[3] == YES)
      levels = Levels.all(m)
      lat, lon = georeference(m)
      writer = IfcWriter.new(project_name: input[0], building_name: input[1], author: input[2],
                             application_version: VERSION, file_name: File.basename(path),
                             latitude: lat, longitude: lon)
      levels.each { |l| writer.add_storey(id: l['id'], name: l['name'], elevation: l['elevation']) }
      records.each { |r| writer.add_element(Records.to_ifc_element(r, levels)) }
      writer.write(path)
      Sketchup.status_text = ''
      UI.messagebox("Esportazione IFC4 completata.\n\n#{records.size} elementi, " \
                    "#{levels.size} livelli.\n#{path}")
      path
    rescue StandardError => e
      UI.messagebox("Errore durante l'esportazione IFC: #{e.message}")
      puts e.backtrace.join("\n")
      nil
    end

    def georeference(m)
      return [nil, nil] unless m.respond_to?(:georeferenced?) && m.georeferenced?

      info = m.shadow_info
      [info['Latitude'], info['Longitude']]
    rescue StandardError
      [nil, nil]
    end

    def export_schedule_csv
      m = model
      rows = Records.schedule_rows(Collector.collect(m), Levels.all(m))
      if rows.empty?
        UI.messagebox('Nessun elemento BIM nel modello.')
        return
      end
      title = m.title.to_s.empty? ? 'modello' : m.title
      path = UI.savepanel('Esporta abaco quantità (CSV)', nil, "#{title}_abaco.csv")
      return unless path

      path += '.csv' unless path.downcase.end_with?('.csv')
      File.open(path, 'wb') { |f| f.write(Records.to_csv(rows).encode('UTF-8')) }
      UI.messagebox("Abaco esportato: #{rows.size} elementi.\n#{path}")
      path
    end

    def export_takeoff_csv
      m = model
      rows = Records.material_takeoff(Collector.collect(m))
      if rows.empty?
        UI.messagebox('Nessun muro con stratigrafia nel modello: assegna una tipologia ai muri.')
        return
      end
      title = m.title.to_s.empty? ? 'modello' : m.title
      path = UI.savepanel('Esporta computo materiali (CSV)', nil, "#{title}_materiali.csv")
      return unless path

      path += '.csv' unless path.downcase.end_with?('.csv')
      File.open(path, 'wb') { |f| f.write(Records.takeoff_csv(rows).encode('UTF-8')) }
      UI.messagebox("Computo materiali esportato: #{rows.size} materiali.\n#{path}")
      path
    end

    def select_guids(guids)
      m = model
      wanted = guids.each_with_object({}) { |g, h| h[g] = true }
      found = []
      m.active_entities.each do |e|
        found << e if BimData.element?(e) && wanted[BimData.guid(e)]
      end
      m.selection.clear
      m.selection.add(found) unless found.empty?
      found.size
    end

    def reverse_section
      UI.messagebox('Nessun piano di sezione nel contesto attivo.') unless Levels.reverse_active_section(model)
    end

    def about
      UI.messagebox("BIMSketch #{VERSION}\n\nEstensione BIM per SketchUp: elementi edilizi " \
                    "parametrici, classificazione IFC, livelli, proprietà, abachi e " \
                    "esportazione IFC4.\n\nLicenza MIT.")
    end
  end
end
