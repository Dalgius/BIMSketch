# frozen_string_literal: true
#
# BIMSketch - autotest da eseguire DENTRO SketchUp.
#
# Uso:
#   1. Installa BIMSketch e riavvia SketchUp.
#   2. File > Nuovo (il test richiede un modello vuoto).
#   3. Estensioni > Developer > Ruby Console, poi digita (con il tuo percorso):
#        load "C:/Users/<utente>/Downloads/autotest.rb"
#      oppure incolla l'intero contenuto di questo file nella console e premi Invio.
#   4. Copia il resoconto stampato nella console e invialo.
#
# Il test crea elementi nel modello corrente e scrive un file IFC e un CSV
# nella cartella temporanea. Al termine puoi chiudere il modello senza salvare.

require 'tmpdir'

module BIMSketchAutotest
  IN3_TO_M3 = 0.0254**3

  @results = []

  class << self
    attr_reader :results

    def model
      Sketchup.active_model
    end

    def check(name)
      detail = yield
      @results << [true, name, detail.to_s]
      puts "  ✓ #{name}#{detail.to_s.empty? ? '' : " — #{detail}"}"
    rescue Exception => e # rubocop:disable Lint/RescueException
      where = (e.backtrace || []).first(3).map { |l| l.sub(/^.*Plugins[\\\/]/, '') }.join(' | ')
      @results << [false, name, "#{e.class}: #{e.message} @ #{where}"]
      puts "  ✗ #{name} — #{e.class}: #{e.message}\n      #{where}"
    end

    def assert(cond, message)
      raise message unless cond
    end

    def approx(actual, expected, tol, what)
      ok = actual && (actual - expected).abs <= tol
      raise format('%s: atteso %.4f, ottenuto %s', what, expected, actual ? format('%.4f', actual) : 'nil') unless ok

      format('%s %.3f', what, actual)
    end

    def volume_m3(entity)
      v = entity.volume
      v > 0 ? v * IN3_TO_M3 : nil
    end

    def pt(x, y, z)
      Geom::Point3d.new(x.m, y.m, z.m)
    end

    # Diagnostica topologica: spigoli che non hanno esattamente due facce.
    def topology(entity)
      edges = entity.definition.entities.grep(Sketchup::Edge)
      open_edges = edges.reject { |e| e.faces.size == 2 }
      "#{entity.definition.entities.grep(Sketchup::Face).size} facce, #{edges.size} spigoli, " \
        "#{open_edges.size} spigoli non chiusi"
    end

    def quantities(entity)
      rec = BIMSketch::Collector.record(model, entity, entity.transformation, false)
      BIMSketch::Records.quantities(rec)
    end

    def qty(entity, name)
      BIMSketch::Quantities.value(quantities(entity), name)
    end

    def run
      @results = []
      @e = {}
      puts '=' * 60
      puts 'BIMSketch autotest'
      puts '=' * 60

      check('Ambiente') do
        assert(defined?(BIMSketch::Builder), 'BIMSketch non è caricata (Extension Manager > abilita BIMSketch)')
        "SketchUp #{Sketchup.version} (#{Sketchup.platform}), Ruby #{RUBY_VERSION}, BIMSketch #{BIMSketch::VERSION}"
      end
      return report unless @results.last[0]

      unless model.entities.length.zero?
        puts '  ✗ Il modello non è vuoto: apri File > Nuovo e riesegui il test.'
        @results << [false, 'Modello vuoto', 'il modello contiene già entità']
        return report
      end

      run_levels
      run_walls
      run_openings
      run_other_elements
      run_classification
      run_data_and_export
      run_ui
      report
    end

    def run_levels
      puts "\n[Livelli]"
      check('Salvataggio livelli') do
        BIMSketch::Levels.save(model, [
                                 { 'id' => 'L0', 'name' => 'Piano Terra', 'elevation' => 0, 'height' => 3 },
                                 { 'id' => 'L1', 'name' => 'Piano Primo', 'elevation' => 3, 'height' => 3 }
                               ])
        BIMSketch::Levels.set_current(model, 'L0')
        names = BIMSketch::Levels.all(model).map { |l| l['name'] }
        assert(names == ['Piano Terra', 'Piano Primo'], "livelli letti: #{names.inspect}")
        "corrente: #{BIMSketch::Levels.current(model)['name']}"
      end
    end

    def run_walls
      puts "\n[Muri]"
      check('Muro 5 m x 0,30 x 3 m') do
        model.start_operation('Autotest muro', true)
        w = BIMSketch::Builder.wall(model, pt(0, 0, 0), pt(5, 0, 0), 0.3.m, 3.m, 'center')
        model.commit_operation
        @e[:wall] = w
        assert(w && w.valid?, 'gruppo non creato')
        assert(BIMSketch::BimData.element?(w), 'non classificato come elemento BIM')
        assert(BIMSketch::Guid.valid?(BIMSketch::BimData.guid(w).to_s), 'GlobalId non valido')
        assert(w.layer.name == 'BIM - Muri', "tag: #{w.layer.name}")
        approx(volume_m3(w), 4.5, 0.001, 'volume m³')
      end
      check('Quantità muro') do
        w = @e[:wall]
        [approx(qty(w, 'Length'), 5.0, 0.001, 'lunghezza'),
         approx(qty(w, 'Width'), 0.3, 0.001, 'spessore'),
         approx(qty(w, 'Height'), 3.0, 0.001, 'altezza'),
         approx(qty(w, 'NetSideArea'), 15.0, 0.01, 'sup. netta')].join(', ')
      end
      check('Giunto d\'angolo (due muri in asse)') do
        model.start_operation('Autotest angolo', true)
        a = BIMSketch::Builder.wall(model, pt(0, 6, 0), pt(4, 6, 0), 0.3.m, 3.m, 'center', ext_end: 0.15.m)
        b = BIMSketch::Builder.wall(model, pt(4, 6, 0), pt(4, 9, 0), 0.3.m, 3.m, 'center', ext_start: -0.15.m)
        model.commit_operation
        assert(a.valid? && b.valid?, 'muri non creati')
        bb = Geom::BoundingBox.new
        bb.add(a.bounds)
        bb.add(b.bounds)
        [approx(volume_m3(a), 4.15 * 0.3 * 3, 0.001, 'vol. A'),
         approx(volume_m3(b), 2.85 * 0.3 * 3, 0.001, 'vol. B'),
         approx(bb.max.x.to_m, 4.15, 0.001, 'spigolo esterno x')].join(', ')
      end
    end

    def run_openings
      puts "\n[Aperture]"
      check('Porta 0,90 x 2,10 nel muro') do
        w = @e[:wall]
        model.start_operation('Autotest porta', true)
        d = BIMSketch::Builder.opening(model, w, 'door', 2.5.m, 0.9.m, 2.1.m, 0)
        model.commit_operation
        @e[:door] = d
        assert(d && d.valid?, 'porta non creata')
        assert(BIMSketch::BimData.read(d)['host'] == BIMSketch::BimData.guid(w), 'porta non collegata al muro')
        vol = volume_m3(w)
        assert(vol, "dopo il taglio il muro NON è più un solido chiuso (#{topology(w)})")
        [approx(vol, 4.5 - 0.9 * 0.3 * 2.1, 0.002, 'vol. muro'),
         approx(qty(d, 'Width'), 0.9, 0.001, 'larghezza porta'),
         approx(qty(d, 'Height'), 2.1, 0.001, 'altezza porta')].join(', ')
      end
      check('Finestra 1,20 x 1,40 (davanzale 0,90)') do
        w = @e[:wall]
        model.start_operation('Autotest finestra', true)
        f = BIMSketch::Builder.opening(model, w, 'window', 1.0.m, 1.2.m, 1.4.m, 0.9.m)
        model.commit_operation
        @e[:window] = f
        assert(f && f.valid?, 'finestra non creata')
        vol = volume_m3(w)
        assert(vol, "dopo il taglio il muro NON è più un solido chiuso (#{topology(w)})")
        bb = f.bounds
        [approx(vol, 4.5 - 0.567 - 0.504, 0.002, 'vol. muro'),
         approx(bb.min.z.to_m, 0.9, 0.001, 'quota davanzale'),
         approx(qty(w, 'NetSideArea'), 15.0 - 1.89 - 1.68, 0.02, 'sup. netta muro')].join(', ')
      end
      check('Aperture registrate nel muro') do
        n = BIMSketch::Builder.wall_openings(@e[:wall]).size
        assert(n == 2, "aperture registrate: #{n}")
        topology(@e[:wall])
      end
      check('Apertura sovrapposta rifiutata') do
        r = BIMSketch::Builder.opening_rect(@e[:wall], 2.5.m, 0.9.m, 2.1.m, 0)
        assert(r.nil?, 'una porta sovrapposta a quella esistente è stata accettata')
        'ok'
      end
      check('Apertura troppo grande rifiutata') do
        r = BIMSketch::Builder.opening_rect(@e[:wall], 2.5.m, 6.m, 2.m, 0)
        assert(r.nil?, 'un\'apertura di 6 m in un muro di 5 m è stata accettata')
        'ok'
      end
    end

    def run_other_elements
      puts "\n[Altri elementi]"
      check('Solaio 5 x 4 x 0,25 sul Piano Primo') do
        BIMSketch::Levels.set_current(model, 'L1')
        model.start_operation('Autotest solaio', true)
        s = BIMSketch::Builder.slab(model, [pt(0, 0, 0), pt(5, 0, 0), pt(5, 4, 0), pt(0, 4, 0)], 0.25.m, 3.m)
        model.commit_operation
        BIMSketch::Levels.set_current(model, 'L0')
        @e[:slab] = s
        assert(BIMSketch::BimData.level_id(s) == 'L1', "livello: #{BIMSketch::BimData.level_id(s)}")
        [approx(volume_m3(s), 5.0, 0.001, 'volume'),
         approx(s.bounds.max.z.to_m, 3.0, 0.001, 'estradosso'),
         approx(qty(s, 'GrossArea'), 20.0, 0.01, 'superficie'),
         approx(qty(s, 'Perimeter'), 18.0, 0.01, 'perimetro')].join(', ')
      end
      check('Pilastro 0,30 x 0,30 x 3') do
        model.start_operation('Autotest pilastro', true)
        c = BIMSketch::Builder.column(model, pt(8, 0, 0), 0.3.m, 0.3.m, 3.m)
        model.commit_operation
        approx(volume_m3(c), 0.27, 0.001, 'volume')
      end
      check('Trave 0,30 x 0,50, estradosso a 3 m') do
        model.start_operation('Autotest trave', true)
        b = BIMSketch::Builder.beam(model, pt(8, 0, 0), pt(8, 4, 0), 0.3.m, 0.5.m, 3.m)
        model.commit_operation
        [approx(volume_m3(b), 4 * 0.15, 0.001, 'volume'),
         approx(b.bounds.max.z.to_m, 3.0, 0.001, 'estradosso')].join(', ')
      end
      check('Spazio da faccia 3 x 3 (altezza 3 m)') do
        model.start_operation('Autotest spazio', true)
        face = model.entities.add_face(pt(10, 0, 0), pt(13, 0, 0), pt(13, 3, 0), pt(10, 3, 0))
        sp = BIMSketch::Commands.element_from_face(face, 'space', :up, 3.m)
        edges = face.edges
        model.entities.erase_entities([face] + edges)
        model.commit_operation
        assert(BIMSketch::BimData.type_key(sp) == 'space', 'non classificato come spazio')
        [approx(volume_m3(sp), 27.0, 0.01, 'volume'),
         approx(qty(sp, 'NetFloorArea'), 9.0, 0.01, 'sup. calpestabile')].join(', ')
      end
      check('Spostamento elementi al cambio quota del livello') do
        list = BIMSketch::Levels.all(model).map(&:dup)
        list.find { |l| l['id'] == 'L1' }['elevation'] = 3.2
        BIMSketch::Levels.update(model, list)
        approx(@e[:slab].bounds.max.z.to_m, 3.2, 0.001, 'estradosso solaio')
      end
    end

    def run_classification
      puts "\n[Classificazione e proprietà]"
      check('Classifica un gruppo esistente come Arredo') do
        model.start_operation('Autotest classifica', true)
        g = model.entities.add_group
        BIMSketch::Geometry.box(g.entities, 1.m, 0.6.m, 0.75.m)
        g.transformation = Geom::Transformation.translation(pt(15, 0, 0))
        BIMSketch::BimData.classify(g, 'furniture', name: 'Tavolo')
        model.commit_operation
        @e[:table] = g
        assert(BIMSketch::BimData.type_key(g) == 'furniture', 'tipo errato')
        assert(g.layer.name == 'BIM - Arredi', "tag: #{g.layer.name}")
        assert(g.material, 'materiale di categoria non assegnato')
        "livello #{BIMSketch::BimData.level_id(g)}, materiale #{g.material.display_name}"
      end
      check('Scrittura e rilettura proprietà (Pset)') do
        w = @e[:wall]
        model.start_operation('Autotest proprietà', true)
        BIMSketch::BimData.write(w, 'name' => 'Muro nord', 'object_type' => 'Laterizio 30',
                                    'material' => 'Laterizio',
                                    'props' => { 'LoadBearing' => true, 'ThermalTransmittance' => '0,28',
                                                 'FireRating' => 'REI 120', 'Sconosciuta' => 'x' },
                                    'custom' => { 'Codice' => 'M-01' })
        model.commit_operation
        d = BIMSketch::BimData.read(w)
        assert(d['name'] == 'Muro nord', "nome: #{d['name']}")
        assert(d['props']['LoadBearing'] == true, "portante: #{d['props']['LoadBearing'].inspect}")
        assert((d['props']['ThermalTransmittance'] - 0.28).abs < 1e-9, 'trasmittanza non convertita')
        assert(!d['props'].key?('Sconosciuta'), 'proprietà sconosciuta non scartata')
        assert(d['custom']['Codice'] == 'M-01', 'proprietà personalizzata persa')
        'ok'
      end
    end

    def run_data_and_export
      puts "\n[Abaco, verifica, IFC]"
      records = nil
      check('Raccolta elementi') do
        records = BIMSketch::Collector.collect(model, mesh: true)
        by_type = records.group_by { |r| r[:type] }.map { |k, v| "#{k}:#{v.size}" }.join(' ')
        assert(records.size >= 10, "trovati solo #{records.size} elementi")
        empty = records.select { |r| r[:mesh][:triangles].empty? }
        assert(empty.empty?, "#{empty.size} elementi senza geometria")
        "#{records.size} elementi (#{by_type})"
      end
      check('Abaco e CSV') do
        rows = BIMSketch::Records.schedule_rows(records, BIMSketch::Levels.all(model))
        path = File.join(Dir.tmpdir, 'bimsketch_autotest.csv')
        File.open(path, 'wb') { |f| f.write(BIMSketch::Records.to_csv(rows)) }
        assert(File.size(path) > 200, 'CSV vuoto')
        "#{rows.size} righe → #{path}"
      end
      check('Verifica modello (GlobalId duplicato simulato)') do
        dup = records.map(&:dup)
        dup[1][:guid] = dup[0][:guid]
        issues = BIMSketch::Checker.analyze(dup, BIMSketch::Levels.all(model))
        assert(issues.any? { |i| i[:code] == 'duplicate_guid' }, 'duplicato non rilevato')
        clean = BIMSketch::Checker.analyze(records, BIMSketch::Levels.all(model))
        errors = clean.select { |i| i[:severity] == 'error' }
        assert(errors.empty?, "errori nel modello di prova: #{errors.map { |i| i[:message] }.join('; ')}")
        "segnalazioni sul modello di prova: #{clean.map { |i| i[:code] }.join(', ')}"
      end
      check('Esportazione IFC4') do
        levels = BIMSketch::Levels.all(model)
        w = BIMSketch::IfcWriter.new(project_name: 'Autotest', application_version: BIMSketch::VERSION)
        levels.each { |l| w.add_storey(id: l['id'], name: l['name'], elevation: l['elevation']) }
        records.each { |r| w.add_element(BIMSketch::Records.to_ifc_element(r, levels)) }
        path = File.join(Dir.tmpdir, 'bimsketch_autotest.ifc')
        w.write(path)
        text = File.read(path)
        %w[IFCWALL IFCDOOR IFCWINDOW IFCSLAB IFCCOLUMN IFCBEAM IFCSPACE IFCFURNITURE].each do |t|
          assert(text.include?("=#{t}("), "#{t} mancante nel file")
        end
        sets = text.scan('=IFCTRIANGULATEDFACESET(').size
        assert(sets == records.size, "#{sets} geometrie per #{records.size} elementi")
        "#{(File.size(path) / 1024.0).round(1)} KB → #{path}"
      end
    end

    def run_ui
      puts "\n[Interfaccia]"
      check('Strumenti attivabili') do
        tools = [BIMSketch::Tools::WallTool.new, BIMSketch::Tools::SlabTool.new,
                 BIMSketch::Tools::ColumnTool.new, BIMSketch::Tools::BeamTool.new,
                 BIMSketch::Tools::OpeningTool.new('door'), BIMSketch::Tools::OpeningTool.new('window')]
        tools.each { |t| model.select_tool(t) }
        model.select_tool(nil)
        "#{tools.size} strumenti"
      end
      check('File dei dialoghi presenti') do
        %w[properties levels schedule checker].each do |n|
          f = File.join(BIMSketch::Dialogs::HTML_DIR, "#{n}.html")
          assert(File.exist?(f), "manca #{f}")
        end
        'ok'
      end
      check('Isola livello e mostra tutto') do
        BIMSketch::Levels.isolate(model, 'L1')
        hidden = model.entities.count { |e| BIMSketch::BimData.element?(e) && e.hidden? }
        BIMSketch::Levels.isolate(model, nil)
        still = model.entities.count { |e| BIMSketch::BimData.element?(e) && e.hidden? }
        assert(hidden > 0 && still.zero?, "nascosti #{hidden}, rimasti nascosti #{still}")
        "#{hidden} elementi nascosti e poi ripristinati"
      end
      check('Vista in pianta del Piano Terra') do
        page = BIMSketch::Levels.create_plan_view(model, 'L0')
        assert(page, 'scena non creata')
        "scena \"#{page.name}\" creata (verifica a occhio, vedi sotto)"
      end
    end

    def report
      ok = @results.count(&:first)
      ko = @results.size - ok
      puts "\n" + '=' * 60
      puts "RISULTATO: #{ok} superati, #{ko} falliti"
      puts '=' * 60
      unless ko.zero?
        puts 'Test falliti:'
        @results.reject(&:first).each { |_, n, d| puts "  - #{n}: #{d}" }
      end
      if @results.any? { |_, n, _| n.start_with?('Vista in pianta') }
        puts "\nCONTROLLO VISIVO: nella scena \"Pianta - Piano Terra\" dovresti vedere dall'alto"
        puts 'i muri tagliati a 1,20 m, con porta e finestra, SENZA il solaio del piano primo.'
        puts "Se invece vedi solo il solaio (o nulla), indica: \"pianta invertita\"."
      end
      puts "\nCopia tutto il testo a partire da \"BIMSketch autotest\" e invialo."
      ::UI.messagebox("BIMSketch autotest: #{ok} superati, #{ko} falliti.\nIl resoconto completo è nella Ruby Console.")
      nil
    end
  end
end

BIMSketchAutotest.run
