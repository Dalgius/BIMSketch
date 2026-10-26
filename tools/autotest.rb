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
  IN3_TO_M3 = 0.0254**3 unless const_defined?(:IN3_TO_M3)

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
      v = BIMSketch::Geometry.respond_to?(:solid_volume) ? BIMSketch::Geometry.solid_volume(entity) : entity.volume
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
      run_separate_walls
      run_openings
      run_opening_types
      run_sketchup_move
      run_other_elements
      run_level_change
      run_classification
      run_wall_types
      run_slab_types
      run_tee_joints
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
      check('Catena aperta a L (giunto d\'angolo in asse)') do
        model.start_operation('Autotest angolo', true)
        a, b = BIMSketch::Builder.wall_chain(model, [pt(0, 6, 0), pt(4, 6, 0), pt(4, 9, 0)], 0.3.m, 3.m)
        model.commit_operation
        assert(a.valid? && b.valid?, 'muri non creati')
        # Quartabuono: lunghezze medie 4 m e 3 m.
        [approx(volume_m3(a), 4.0 * 0.3 * 3, 0.001, 'vol. A'),
         approx(volume_m3(b), 3.0 * 0.3 * 3, 0.001, 'vol. B')].join(', ')
      end
      [['center', 5.3 * 4.3 - 4.7 * 3.7, [-0.15, 5.15]],
       ['left', 5 * 4 - 4.4 * 3.4, [0, 5]],
       ['right', 5.6 * 4.6 - 5 * 4, [-0.3, 5.3]]].each_with_index do |(align, area, xs), k|
        check("Anello chiuso 5 x 4, allineamento #{align}") do
          y0 = 20 + k * 8
          pts = [pt(20, y0, 0), pt(25, y0, 0), pt(25, y0 + 4, 0), pt(20, y0 + 4, 0)]
          model.start_operation('Autotest anello', true)
          walls = BIMSketch::Builder.wall_chain(model, pts, 0.3.m, 3.m, align, closed: true)
          model.commit_operation
          assert(walls.size == 4 && walls.all?(&:valid?), 'muri non creati')
          bb = Geom::BoundingBox.new
          walls.each { |w| bb.add(w.bounds) }
          [approx(walls.sum { |w| volume_m3(w) || 0 }, area * 3, 0.001, 'volume totale'),
           approx(bb.min.x.to_m - 20, xs[0], 0.001, 'bordo esterno'),
           approx(bb.max.x.to_m - 20, xs[1], 0.001, 'bordo opposto')].join(', ')
        end
      end
    end

    # Muri disegnati uno alla volta, ogni volta partendo vicino allo spigolo del
    # precedente (come con lo strumento Muro): devono agganciarsi e raccordarsi.
    def run_separate_walls
      [['center', [[0, 0], [5, 0], [5, 4], [0, 4]], 5.3 * 4.3 - 4.7 * 3.7],
       ['left', [[0, 0], [0, 4], [5, 4], [5, 0]], 5.6 * 4.6 - 5 * 4]].each_with_index do |(align, corners, area), k|
        check("Muri separati agganciati in perimetro, allineamento #{align}") do
          x0 = 40
          y0 = 20 + k * 8
          guid = nil
          walls = []
          closed = nil
          corners.each_with_index do |(cx, cy), i|
            nx, ny = corners[(i + 1) % corners.size]
            # Il clic iniziale cade a 10-15 cm dall'estremità del muro precedente.
            jitter = i.zero? ? 0 : 0.12
            a = pt(x0 + cx + jitter, y0 + cy - jitter, 0)
            b = pt(x0 + nx + (i == corners.size - 1 ? 0.1 : 0), y0 + ny + (i == corners.size - 1 ? 0.08 : 0), 0)
            model.start_operation('Autotest muro separato', true)
            res = BIMSketch::Builder.wall_connected(model, a, b, 0.3.m, 3.m, align)
            model.commit_operation
            assert(res, "muro #{i + 1} non creato")
            walls << res[:wall]
            guid ||= BIMSketch::BimData.guid(res[:wall])
            closed = res[:joined_end]
          end
          assert(closed, "l'ultimo muro non si è agganciato al primo")
          assert(walls.all?(&:valid?), 'un muro è stato cancellato')
          assert(BIMSketch::BimData.guid(walls.first) == guid, 'il primo muro ha perso il suo GlobalId')
          approx(walls.sum { |w| volume_m3(w) || 0 }, area * 3, 0.002, 'volume totale')
        end
      end
      check('Perimetro irregolare (angoli non retti) disegnato a mano') do
        # Le stesse estremità del perimetro segnalato dall'utente.
        corners = [[0, 0], [0, 3.799], [2.941, 3.263], [2.390, -1.443]]
        x0 = 60
        y0 = 20
        walls = []
        closed = nil
        corners.each_with_index do |(cx, cy), i|
          nx, ny = corners[(i + 1) % corners.size]
          model.start_operation('Autotest perimetro irregolare', true)
          res = BIMSketch::Builder.wall_connected(model, pt(x0 + cx, y0 + cy, 0), pt(x0 + nx, y0 + ny, 0),
                                                  0.3.m, 3.m, 'left')
          model.commit_operation
          assert(res, "muro #{i + 1} non creato")
          walls << res[:wall]
          closed = res[:joined_end]
        end
        assert(closed, "l'ultimo muro non si è agganciato al primo")
        lo, hi = BIMSketch::WallJoint.band('left', 0.3)
        exts = BIMSketch::WallJoint.chain(corners, lo, hi, closed: true)
        area = corners.each_with_index.sum do |(cx, cy), i|
          nx, ny = corners[(i + 1) % corners.size]
          BIMSketch::WallJoint.area(BIMSketch::WallJoint.footprint(Math.hypot(nx - cx, ny - cy), 0.3, exts[i]))
        end
        solid = walls.all? { |w| volume_m3(w) }
        assert(solid, 'un muro con testate oblique non è un solido chiuso')
        approx(walls.sum { |w| volume_m3(w) }, area * 3, 0.002, 'volume totale')
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
        @e[:column] = c
        approx(volume_m3(c), 0.27, 0.001, 'volume')
      end
      check('Trave 0,30 x 0,50, estradosso a 3 m') do
        model.start_operation('Autotest trave', true)
        b = BIMSketch::Builder.beam(model, pt(8, 0, 0), pt(8, 4, 0), 0.3.m, 0.5.m, 3.m)
        model.commit_operation
        @e[:beam] = b
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
      check('Altezza automatica al cambio altezza del livello') do
        set_level_height('L0', 3.5)
        w = @e[:wall]
        assert(BIMSketch::Levels.skipped_last_update.zero?,
               "#{BIMSketch::Levels.skipped_last_update} elementi non adattati")
        [approx(height_m(w), 3.5, 0.001, 'altezza muro'),
         approx(volume_m3(w), 5 * 0.3 * 3.5 - 0.567 - 0.504, 0.002, 'volume muro con aperture'),
         approx(height_m(@e[:column]), 3.5, 0.001, 'altezza pilastro'),
         approx(@e[:beam].bounds.max.z.to_m, 3.5, 0.001, 'estradosso trave')].join(', ')
      end
      check('Altezza numerica (non segue più il livello)') do
        model.start_operation('Autotest altezza', true)
        ok = BIMSketch::Builder.set_height(model, @e[:column], height: 2.7.m, auto: false)
        model.commit_operation
        assert(ok, 'altezza del pilastro non impostata')
        set_level_height('L0', 3.0)
        info = BIMSketch::Builder.element_height(model, @e[:column])
        assert(info[:auto] == false, 'il pilastro risulta ancora automatico')
        [approx(height_m(@e[:column]), 2.7, 0.001, 'altezza pilastro (fissa)'),
         approx(height_m(@e[:wall]), 3.0, 0.001, 'altezza muro (automatica)'),
         approx(@e[:beam].bounds.max.z.to_m, 3.0, 0.001, 'estradosso trave')].join(', ')
      end
      check('Altezza troppo bassa per le aperture rifiutata') do
        model.start_operation('Autotest altezza bassa', true)
        ok = BIMSketch::Builder.set_height(model, @e[:wall], height: 2.0.m, auto: false)
        model.commit_operation
        assert(!ok, 'il muro è stato abbassato sotto la porta')
        approx(height_m(@e[:wall]), 3.0, 0.001, 'altezza invariata')
      end
    end

    def run_level_change
      check('Cambio livello sposta solaio, muro, finestra, pilastro e trave') do
        b = BIMSketch::Builder
        BIMSketch::Levels.set_current(model, 'L0')
        l0 = BIMSketch::Levels.find(model, 'L0')
        model.start_operation('Autotest cambio livello', true)
        s = b.slab(model, [pt(40, 0, 0), pt(44, 0, 0), pt(44, 3, 0), pt(40, 3, 0)], 0.25.m, 0)
        w = b.wall(model, pt(40, 10, 0), pt(44, 10, 0), 0.3.m, 3.m, 'center')
        win = b.opening(model, w, 'window', 2.m, 1.2.m, 1.4.m, 0.9.m)
        c = b.column(model, pt(46, 0, 0), 0.3.m, 0.3.m, l0['height'].m)
        bm = b.beam(model, pt(46, 0, 0), pt(46, 4, 0), 0.3.m, 0.5.m, (l0['elevation'] + l0['height']).m)
        model.commit_operation
        l1 = BIMSketch::Levels.find(model, 'L1')
        model.start_operation('Autotest relocate', true)
        skipped = BIMSketch::Levels.relocate(model, [s, w, c, bm], 'L1')
        model.commit_operation
        assert(skipped.zero?, "#{skipped} altezze non adattate")
        assert([s, w, win, c, bm].all? { |e| BIMSketch::BimData.level_id(e) == 'L1' }, 'livello non assegnato')
        [approx(s.bounds.max.z.to_m, l1['elevation'], 0.001, 'estradosso solaio'),
         approx(w.bounds.min.z.to_m, l1['elevation'], 0.001, 'base muro'),
         approx(height_m(w), l1['height'], 0.001, 'altezza muro'),
         approx(win.bounds.min.z.to_m, l1['elevation'] + 0.9, 0.001, 'davanzale finestra'),
         approx(c.bounds.min.z.to_m, l1['elevation'], 0.001, 'base pilastro'),
         approx(height_m(c), l1['height'], 0.001, 'altezza pilastro'),
         approx(bm.bounds.max.z.to_m, l1['elevation'] + l1['height'], 0.001, 'estradosso trave')].join(', ')
      end
    end

    def parts_of(entity)
      entity.definition.entities.select { |e| e.is_a?(Sketchup::Group) && e.get_attribute('BIMSketch', 'part') }
    end

    def run_opening_types
      puts "\n[Tipologie porte e finestre]"
      b = BIMSketch::Builder
      { 'door' => 140, 'window' => 150 }.each do |kind, y|
        BIMSketch::OpeningTypes.all(kind).each_with_index do |t, i|
          check("#{t['name']} (#{t['id']})") do
            model.start_operation('Autotest tipologia apertura', true)
            @e[:"host_#{kind}"] ||= b.wall(model, pt(0, y, 0), pt(8, y, 0), 0.3.m, 3.m, 'center')
            o = b.opening(model, @e[:"host_#{kind}"], kind, [1.0, 2.6, 4.2, 6.0][i].m, t['width'].m,
                          t['height'].m, t['sill'].m, type_id: t['id'])
            model.commit_operation
            assert(o, 'apertura non creata')
            parts = parts_of(o)
            assert(parts.all? { |p| p.volume > 0 }, 'una parte non è un solido')
            frame = parts.find { |p| p.name == 'Telaio' }
            assert(frame && frame.material && frame.material.alpha > 0.99, 'telaio mancante o trasparente')
            glass = parts.count { |p| p.name == 'Vetro' }
            glazed = kind == 'window' || t['style'] == 'glazed'
            assert(glazed ? glass >= 1 : glass.zero?, "vetri: #{glass}")
            assert(BIMSketch::BimData.read(o)['object_type'] == t['name'], 'tipologia non scritta')
            [approx((o.bounds.max.x - o.bounds.min.x).to_m, t['width'], 0.002, 'larghezza'),
             approx(o.bounds.min.z.to_m, t['sill'], 0.002, 'quota'),
             "#{parts.size} parti, #{glass} vetri"].join(', ')
          end
        end
      end
      check('Cambio tipologia: finestra a due ante → un\'anta → due ante') do
        b = BIMSketch::Builder
        wall = @e[:host_window]
        win = model.entities.find do |e|
          BIMSketch::BimData.element?(e) && e.get_attribute('BIMSketch', 'opening_type') == 'W2' &&
            e.get_attribute('BIMSketch', 'host') == BIMSketch::BimData.guid(wall)
        end
        guid = BIMSketch::BimData.guid(win)
        vol = volume_m3(wall)
        model.start_operation('Autotest cambio tipologia apertura', true)
        ok = b.change_opening_type(model, win, 'W1')
        model.commit_operation
        assert(ok, 'tipologia non cambiata')
        assert(BIMSketch::BimData.guid(win) == guid, 'GlobalId cambiato')
        assert(BIMSketch::BimData.read(win)['object_type'] == "Finestra a un'anta", 'ObjectType non aggiornato')
        res = [approx((win.bounds.max.x - win.bounds.min.x).to_m, 0.8, 0.002, 'larghezza'),
               approx(volume_m3(wall), vol + 0.4 * 1.4 * 0.3, 0.002, 'volume muro (foro più stretto)')]
        model.start_operation('Autotest ripristino tipologia apertura', true)
        ok = b.change_opening_type(model, win, 'W2')
        model.commit_operation
        assert(ok, 'ritorno a due ante non riuscito')
        res << approx(volume_m3(wall), vol, 0.002, 'volume muro ripristinato')
        res.join(', ')
      end
      check('Cambio tipologia che non entra nel muro rifiutato') do
        b = BIMSketch::Builder
        model.start_operation('Autotest muro corto', true)
        short = b.wall(model, pt(0, 160, 0), pt(1.2, 160, 0), 0.3.m, 3.m, 'center')
        door = b.opening(model, short, 'door', 0.6.m, 0.9.m, 2.1.m, 0, type_id: 'D1')
        model.commit_operation
        model.start_operation('Autotest cambio tipologia rifiutato', true)
        ok = b.change_opening_type(model, door, 'D2') # 1,40 m in un muro lungo 1,20 m
        model.commit_operation
        assert(!ok, 'cambio accettato anche se la porta non entra')
        approx((door.bounds.max.x - door.bounds.min.x).to_m, 0.9, 0.002, 'larghezza invariata')
      end
      check('Sposta finestra lungo il muro e cambia davanzale') do
        b = BIMSketch::Builder
        wall = @e[:host_window]
        win = model.entities.find do |e|
          BIMSketch::BimData.element?(e) && e.get_attribute('BIMSketch', 'opening_type') == 'W4' &&
            e.get_attribute('BIMSketch', 'host') == BIMSketch::BimData.guid(wall)
        end
        guid = BIMSketch::BimData.guid(win)
        vol = volume_m3(wall)
        n = b.wall_openings(wall).size
        model.start_operation('Autotest sposta finestra', true)
        out = b.move_opening(model, win, left: 7.0.m) # 7,00 + 1,00 > 8,00 - 0,01: fuori dal muro
        moved = b.move_opening(model, win, left: 6.8.m)
        raised = b.move_opening(model, win, sill: 1.2.m)
        model.commit_operation
        assert(!out, 'posizione fuori dal muro accettata')
        assert(moved && raised, 'spostamento non riuscito')
        assert(BIMSketch::BimData.guid(win) == guid, 'GlobalId cambiato')
        assert(b.wall_openings(wall).size == n, "aperture nel muro: #{b.wall_openings(wall).size} invece di #{n}")
        pos = b.opening_position(model, win)
        [approx(pos[:left].to_m, 6.8, 0.001, 'distanza dall\'inizio'),
         approx(win.bounds.min.x.to_m, 6.8, 0.002, 'posizione'),
         approx(win.bounds.min.z.to_m, 1.2, 0.002, 'davanzale'),
         approx(volume_m3(wall), vol, 0.002, 'volume muro invariato')].join(', ')
      end
      check('Spostamento sopra un\'altra apertura rifiutato') do
        b = BIMSketch::Builder
        wall = @e[:host_window]
        vasistas = model.entities.find do |e|
          BIMSketch::BimData.element?(e) && e.get_attribute('BIMSketch', 'opening_type') == 'W3' &&
            e.get_attribute('BIMSketch', 'host') == BIMSketch::BimData.guid(wall)
        end
        model.start_operation('Autotest sposta sovrapposto', true)
        ok = b.move_opening(model, vasistas, left: 2.5.m, sill: 0.9.m) # sopra la finestra a due ante
        model.commit_operation
        assert(!ok, 'sovrapposizione accettata')
        approx(vasistas.bounds.min.x.to_m, 3.8, 0.002, 'posizione invariata')
      end
      check('Tipo di apertura nell\'IFC') do
        records = BIMSketch::Collector.collect(model, mesh: true)
        levels = BIMSketch::Levels.all(model)
        w = BIMSketch::IfcWriter.new(project_name: 'Autotest')
        levels.each { |l| w.add_storey(id: l['id'], name: l['name'], elevation: l['elevation']) }
        records.each { |r| w.add_element(BIMSketch::Records.to_ifc_element(r, levels)) }
        text = w.to_s
        %w[.DOUBLE_DOOR_SINGLE_SWING. .SLIDING_TO_LEFT. .DOUBLE_PANEL_VERTICAL.].each do |op|
          assert(text.include?(op), "#{op} mancante")
        end
        'OperationType e PartitioningType presenti'
      end
    end

    def find_opening(wall, type_id)
      model.entities.find do |e|
        BIMSketch::BimData.element?(e) && e.get_attribute('BIMSketch', 'opening_type') == type_id &&
          e.get_attribute('BIMSketch', 'host') == BIMSketch::BimData.guid(wall)
      end
    end

    # Simula uno spostamento fatto con lo Sposta di SketchUp e la correzione
    # automatica che BIMSketch fa al termine dell'operazione.
    def sketchup_move(entity, vector, copy: false)
      model.start_operation('Autotest Sposta di SketchUp', true)
      target = copy ? entity.copy : entity
      target.transform!(Geom::Transformation.translation(vector))
      model.commit_operation
      model.start_operation('Autotest correzione aperture', true)
      messages = BIMSketch::OpeningSync.process(model)
      model.commit_operation
      [target, messages]
    end

    def run_sketchup_move
      puts "\n[Sposta di SketchUp]"
      b = BIMSketch::Builder
      wall = @e[:host_window]
      check('Finestra spostata lungo il muro: il foro segue') do
        w1 = find_opening(wall, 'W1')
        vol = volume_m3(wall)
        _, msgs = sketchup_move(w1, Geom::Vector3d.new(0.5.m, 0, 0))
        assert(msgs.empty?, msgs.join(' '))
        assert(BIMSketch::OpeningSync.candidates(model).empty?, 'aperture non allineate')
        [approx(b.opening_position(model, w1)[:left].to_m, 1.1, 0.001, 'distanza dall\'inizio'),
         approx(volume_m3(wall), vol, 0.002, 'volume muro invariato')].join(', ')
      end
      check('Finestra spostata in alto: cambia il davanzale') do
        w1 = find_opening(wall, 'W1')
        _, msgs = sketchup_move(w1, Geom::Vector3d.new(0, 0, 0.2.m))
        assert(msgs.empty?, msgs.join(' '))
        approx(b.opening_position(model, w1)[:sill].to_m, 1.1, 0.001, 'davanzale')
      end
      check('Spostamento sopra un\'altra finestra: torna al suo posto') do
        w1 = find_opening(wall, 'W1')
        _, msgs = sketchup_move(w1, Geom::Vector3d.new(1.0.m, 0, 0))
        assert(msgs.size == 1, "messaggi: #{msgs.inspect}")
        assert(BIMSketch::OpeningSync.candidates(model).empty?, 'apertura non riportata al suo posto')
        approx(b.opening_position(model, w1)[:left].to_m, 1.1, 0.001, 'distanza invariata')
      end
      check('Finestra portata lontano dal muro: torna al suo posto') do
        w1 = find_opening(wall, 'W1')
        _, msgs = sketchup_move(w1, Geom::Vector3d.new(0, 3.m, 0))
        assert(msgs.size == 1, "messaggi: #{msgs.inspect}")
        approx(w1.bounds.center.y.to_m, 150.0, 0.01, 'di nuovo nel muro')
      end
      check('Copia con Ctrl: diventa una nuova finestra') do
        w1 = find_opening(wall, 'W1')
        n = b.wall_openings(wall).size
        vol = volume_m3(wall)
        copy, msgs = sketchup_move(w1, Geom::Vector3d.new(4.4.m, 0, 0), copy: true)
        assert(msgs.empty?, msgs.join(' '))
        assert(copy.valid?, 'copia eliminata')
        assert(BIMSketch::BimData.guid(copy) != BIMSketch::BimData.guid(w1), 'GlobalId duplicato')
        assert(b.wall_openings(wall).size == n + 1, 'foro della copia mancante')
        [approx(b.opening_position(model, copy)[:left].to_m, 5.5, 0.001, 'posizione copia'),
         approx(volume_m3(wall), vol - 0.8 * 1.4 * 0.3, 0.002, 'volume muro')].join(', ')
      end
      check('Copia sopra un\'altra finestra: eliminata') do
        w1 = find_opening(wall, 'W1')
        n = b.wall_openings(wall).size
        copy, msgs = sketchup_move(w1, Geom::Vector3d.new(1.2.m, 0, 0), copy: true)
        assert(msgs.size == 1 && !copy.valid?, "copia non eliminata (#{msgs.inspect})")
        assert(b.wall_openings(wall).size == n, 'fori cambiati')
        'ok'
      end
      check('Muro spostato da solo: le finestre lo seguono') do
        _, msgs = sketchup_move(wall, Geom::Vector3d.new(0, 0.5.m, 0))
        assert(msgs.empty?, msgs.join(' '))
        assert(BIMSketch::OpeningSync.candidates(model).empty?, 'aperture rimaste indietro')
        approx(find_opening(wall, 'W2').bounds.center.y.to_m, 150.5, 0.01, 'finestra a due ante')
      end
    end

    def set_level_height(id, height)
      list = BIMSketch::Levels.all(model).map(&:dup)
      list.find { |l| l['id'] == id }['height'] = height
      BIMSketch::Levels.update(model, list)
    end

    def height_m(entity)
      (entity.bounds.max.z - entity.bounds.min.z).to_m
    end

    def layers_of(wall)
      wall.definition.entities.select { |e| e.is_a?(Sketchup::Group) && e.get_attribute('BIMSketch', 'layer') }
    end

    def ring_volume(t, h)
      ((5 + t) * (4 + t) - (5 - t) * (4 - t)) * h
    end

    def run_wall_types
      puts "\n[Stratigrafie]"
      lib = BIMSketch::WallTypeLibrary
      check('Libreria tipologie') do
        types = lib.all(model)
        model.start_operation('Autotest libreria', true)
        lib.save(model, types)
        model.commit_operation
        t = lib.find(model, 'WT1')
        assert(t, 'tipologia WT1 mancante')
        "#{lib.all(model).size} tipologie, WT1 = #{BIMSketch::WallTypes.summary(t)}"
      end
      check('Muro con stratigrafia (WT1, 42,5 cm)') do
        model.start_operation('Autotest muro a strati', true)
        w = BIMSketch::Builder.wall(model, pt(0, 60, 0), pt(5, 60, 0), 0.3.m, 3.m, 'center', type_id: 'WT1')
        model.commit_operation
        @e[:layered] = w
        layers = layers_of(w)
        assert(layers.size == 4, "strati creati: #{layers.size}")
        assert(layers.all? { |l| l.volume > 0 }, 'uno strato non è un solido')
        t = lib.find(model, 'WT1')
        u = BIMSketch::WallTypes.u_value(t, external: false)
        props = BIMSketch::BimData.json_attr(w, 'props')
        assert((props['ThermalTransmittance'].to_f - u).abs < 1e-3, "U nel Pset: #{props['ThermalTransmittance']}")
        assert(BIMSketch::BimData.read(w)['object_type'] == t['name'], 'tipologia non scritta come ObjectType')
        [approx(volume_m3(w), 5 * 0.425 * 3, 0.002, 'volume'),
         approx(volume_m3(layers.max_by { |l| l.volume }), 5 * 0.30 * 3, 0.002, 'volume muratura'),
         format('U %.3f W/m²K', u)].join(', ')
      end
      check('Porta in muro a strati (taglia tutti gli strati)') do
        w = @e[:layered]
        model.start_operation('Autotest porta strati', true)
        d = BIMSketch::Builder.opening(model, w, 'door', 2.5.m, 0.9.m, 2.1.m, 0)
        model.commit_operation
        assert(d, 'porta non creata')
        assert(layers_of(w).all? { |l| l.volume > 0 }, 'uno strato non è più un solido')
        approx(volume_m3(w), 5 * 0.425 * 3 - 0.9 * 2.1 * 0.425, 0.002, 'volume')
      end
      check('Anello 5 x 4 a strati (WT2) con quartabuono') do
        pts = [pt(20, 70, 0), pt(25, 70, 0), pt(25, 74, 0), pt(20, 74, 0)]
        model.start_operation('Autotest anello strati', true)
        walls = BIMSketch::Builder.wall_chain(model, pts, 0.3.m, 3.m, 'center', closed: true, type_id: 'WT2')
        model.commit_operation
        @e[:ring] = walls
        assert(walls.all? { |w| layers_of(w).size == 3 }, 'strati mancanti')
        approx(walls.sum { |w| volume_m3(w) || 0 }, ring_volume(0.33, 3), 0.002, 'volume totale')
      end
      check('Modifica della tipologia aggiorna muri e giunti') do
        types = lib.all(model)
        wt2 = types.find { |t| t['id'] == 'WT2' }
        wt2['layers'][1]['thickness'] = 0.20
        model.start_operation('Autotest modifica tipologia', true)
        lib.save(model, types)
        failed = BIMSketch::Builder.update_type_walls(model, 'WT2')
        model.commit_operation
        assert(failed.zero?, "#{failed} muri non aggiornati")
        walls = @e[:ring]
        assert(walls.all?(&:valid?), 'un muro è stato cancellato')
        approx(walls.sum { |w| volume_m3(w) || 0 }, ring_volume(0.23, 3), 0.002, 'volume totale (23 cm)')
      end
      check('Cambio tipologia di un singolo muro') do
        w = @e[:ring].first
        model.start_operation('Autotest cambio tipologia', true)
        ok = BIMSketch::Builder.apply_wall_type(model, w, 'WT3')
        model.commit_operation
        assert(ok, 'tipologia non applicata')
        g = BIMSketch::Builder.wall_geom(w)
        assert(@e[:ring].all? { |x| volume_m3(x) }, 'un muro dell\'anello non è più solido')
        approx(g[:thickness].to_m, 0.11, 0.0005, 'spessore')
      end
      check('Stratigrafia nell\'IFC e nel computo materiali') do
        records = BIMSketch::Collector.collect(model, mesh: true)
        rec = records.find { |r| r[:entity] == @e[:layered] }
        assert(rec[:layers] && rec[:layers].size == 4, 'strati non raccolti')
        assert(rec[:mesh_parts] && rec[:mesh_parts].size == 4, 'geometria per strato mancante')
        levels = BIMSketch::Levels.all(model)
        w = BIMSketch::IfcWriter.new(project_name: 'Autotest')
        levels.each { |l| w.add_storey(id: l['id'], name: l['name'], elevation: l['elevation']) }
        records.each { |r| w.add_element(BIMSketch::Records.to_ifc_element(r, levels)) }
        text = w.to_s
        assert(text.include?('=IFCMATERIALLAYERSET('), 'IfcMaterialLayerSet mancante')
        takeoff = BIMSketch::Records.material_takeoff(records)
        eps = takeoff.find { |r| r['material'] == 'EPS con grafite' }
        assert(eps, 'materiale isolante assente dal computo')
        "#{text.scan('=IFCMATERIALLAYERSET(').size} stratigrafie IFC, isolante #{format('%.3f', eps['volume'])} m³"
      end
    end


    def run_slab_types
      puts "\n[Solai a strati]"
      lib = BIMSketch::WallTypeLibrary
      b = BIMSketch::Builder
      check('Libreria tipologie solaio') do
        types = lib.all(model, kind: 'slab')
        assert(types.size == 3 && lib.find(model, 'ST1', kind: 'slab'), "tipologie: #{types.map { |t| t['id'] }}")
        "#{types.size} tipologie, ST1 = #{BIMSketch::WallTypes.summary(lib.find(model, 'ST1', kind: 'slab'))}"
      end
      check('Solaio 5 x 4 con stratigrafia (ST1, 34 cm)') do
        model.start_operation('Autotest solaio a strati', true)
        s = b.slab(model, [pt(0, 120, 0), pt(5, 120, 0), pt(5, 124, 0), pt(0, 124, 0)], 0.25.m, 6.m,
                   type_id: 'ST1')
        model.commit_operation
        @e[:layered_slab] = s
        layers = layers_of(s)
        assert(layers.size == 5, "strati creati: #{layers.size}")
        assert(layers.all? { |l| l.volume > 0 }, 'uno strato non è un solido')
        t = lib.find(model, 'ST1', kind: 'slab')
        u = BIMSketch::WallTypes.u_value(t, external: false, flow: :down)
        props = BIMSketch::BimData.json_attr(s, 'props')
        assert((props['ThermalTransmittance'].to_f - u).abs < 1e-3, "U nel Pset: #{props['ThermalTransmittance']}")
        assert(BIMSketch::BimData.read(s)['object_type'] == t['name'], 'tipologia non scritta come ObjectType')
        top = layers.max_by { |l| l.bounds.max.z }
        assert(top.name == 'Pavimento', "strato superiore: #{top.name}")
        [approx(volume_m3(s), 5 * 4 * 0.34, 0.002, 'volume'),
         approx(s.bounds.max.z.to_m, 6.0, 0.001, 'estradosso'),
         approx(s.bounds.min.z.to_m, 5.66, 0.001, 'intradosso'),
         approx(qty(s, 'GrossArea'), 20.0, 0.01, 'superficie (senza facce interne)'),
         format('U %.3f W/m²K', u)].join(', ')
      end
      check('Tipologia assegnata a un solaio esistente (estradosso fermo)') do
        s = @e[:slab]
        top = s.bounds.max.z.to_m
        model.start_operation('Autotest assegna tipologia solaio', true)
        ok = b.apply_slab_type(model, s, 'ST2')
        model.commit_operation
        assert(ok, 'tipologia non applicata')
        assert(layers_of(s).size == 4, "strati: #{layers_of(s).size}")
        [approx(s.bounds.max.z.to_m, top, 0.001, 'estradosso'),
         approx(volume_m3(s), 5 * 4 * 0.315, 0.002, 'volume')].join(', ')
      end
      check('Solaio da faccia con stratigrafia') do
        model.start_operation('Autotest solaio da faccia', true)
        face = model.entities.add_face(pt(10, 120, 9), pt(14, 120, 9), pt(14, 123, 9), pt(10, 123, 9))
        s = BIMSketch::Commands.element_from_face(face, 'slab', :down, 0.2.m)
        model.entities.erase_entities([face] + face.edges)
        assert(b.parametric_slab?(s), 'solaio da faccia non riconosciuto')
        ok = b.apply_slab_type(model, s, 'ST1')
        model.commit_operation
        @e[:face_slab] = s
        assert(ok, 'tipologia non applicata')
        [approx(s.bounds.max.z.to_m, 9.0, 0.001, 'estradosso'),
         approx(volume_m3(s), 4 * 3 * 0.34, 0.002, 'volume')].join(', ')
      end
      check('Modifica della tipologia aggiorna i solai') do
        types = lib.all(model, kind: 'slab')
        types.find { |t| t['id'] == 'ST1' }['layers'][1]['thickness'] = 0.08
        model.start_operation('Autotest modifica tipologia solaio', true)
        lib.save(model, types, kind: 'slab')
        failed = b.update_type_slabs(model, 'ST1')
        model.commit_operation
        assert(failed.zero?, "#{failed} solai non aggiornati")
        [approx(volume_m3(@e[:layered_slab]), 5 * 4 * 0.36, 0.002, 'volume solaio'),
         approx(volume_m3(@e[:face_slab]), 4 * 3 * 0.36, 0.002, 'volume solaio da faccia'),
         approx(@e[:layered_slab].bounds.max.z.to_m, 6.0, 0.001, 'estradosso')].join(', ')
      end
      check('Rimozione della tipologia (solaio unico)') do
        s = @e[:face_slab]
        model.start_operation('Autotest rimuovi tipologia solaio', true)
        ok = b.apply_slab_type(model, s, nil)
        model.commit_operation
        assert(ok && layers_of(s).empty?, 'strati ancora presenti')
        assert(s.volume > 0, 'il solaio non è un solido')
        approx(volume_m3(s), 4 * 3 * 0.36, 0.002, 'volume (spessore mantenuto)')
      end
      check('Stratigrafia dei solai nell\'IFC e nel computo') do
        records = BIMSketch::Collector.collect(model, mesh: true)
        rec = records.find { |r| r[:entity] == @e[:layered_slab] }
        assert(rec[:layers] && rec[:layers].size == 5, 'strati non raccolti')
        assert(rec[:mesh_parts] && rec[:mesh_parts].size == 5, 'geometria per strato mancante')
        takeoff = BIMSketch::Records.material_takeoff(records)
        xps = takeoff.find { |r| r['material'] == 'XPS' }
        assert(xps, 'isolante del solaio assente dal computo')
        approx(xps['volume'], 5 * 4 * 0.10, 0.002, 'volume XPS (ST2)')
      end
    end

    def run_tee_joints
      puts "\n[Giunti a T]"
      b = BIMSketch::Builder
      check('Muro che termina sul corpo di un altro (T perpendicolare)') do
        model.start_operation('Autotest T', true)
        host = b.wall(model, pt(0, 100, 0), pt(6, 100, 0), 0.3.m, 3.m, 'center')
        # Clic finale 10 cm dentro il muro principale: il punto va proiettato sul suo asse.
        res = b.wall_connected(model, pt(3, 103, 0), pt(3, 100.1, 0), 0.3.m, 3.m, 'center')
        model.commit_operation
        @e[:tee_host] = host
        @e[:tee_a] = res[:wall]
        assert(res[:joined_end], 'il muro non si è agganciato al muro principale')
        p2 = b.wall_params(model, res[:wall])[:p2]
        [approx(p2.y.to_m, 100.0, 0.001, 'aggancio sull\'asse'),
         approx(p2.x.to_m, 3.0, 0.001, 'aggancio x'),
         approx(volume_m3(res[:wall]), 2.85 * 0.3 * 3, 0.002, 'volume muro a T'),
         approx(volume_m3(host), 6 * 0.3 * 3, 0.002, 'muro principale invariato')].join(', ')
      end
      check('Muro che parte dal corpo di un altro') do
        model.start_operation('Autotest T inizio', true)
        res = b.wall_connected(model, pt(1.5, 99.9, 0), pt(1.5, 97, 0), 0.3.m, 3.m, 'center')
        model.commit_operation
        @e[:tee_b] = res[:wall]
        approx(volume_m3(res[:wall]), 2.85 * 0.3 * 3, 0.002, 'volume')
      end
      check('Giunto a T obliquo') do
        model.start_operation('Autotest T obliquo', true)
        res = b.wall_connected(model, pt(4, 103, 0), pt(5.02, 100.05, 0), 0.3.m, 3.m, 'center')
        model.commit_operation
        j = BIMSketch::WallJoint
        a = [4.0, 3.0]
        e = [5.02, 0.0]
        d = j.direction(a, e)
        s_tee = j.tee(e, d, [-0.15, 0.15], [0.0, 0.0], [1.0, 0.0], 0.15)
        area = j.area(j.footprint(Math.hypot(e[0] - a[0], e[1] - a[1]), 0.3, [0, 0, s_tee[0], s_tee[1]]))
        approx(volume_m3(res[:wall]), area * 3, 0.002, 'volume')
      end
      check('Il muro a T segue il cambio di spessore del muro principale') do
        model.start_operation('Autotest T tipologia', true)
        ok = b.apply_wall_type(model, @e[:tee_host], 'WT1')
        model.commit_operation
        assert(ok, 'tipologia non applicata al muro principale')
        [approx(volume_m3(@e[:tee_a]), (3 - 0.2125) * 0.3 * 3, 0.002, 'volume muro a T'),
         approx(volume_m3(@e[:tee_b]), (3 - 0.2125) * 0.3 * 3, 0.002, 'volume muro opposto')].join(', ')
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
        expected = records.sum { |r| r[:mesh_parts] ? r[:mesh_parts].size : 1 }
        assert(sets == expected, "#{sets} geometrie invece di #{expected}")
        "#{(File.size(path) / 1024.0).round(1)} KB → #{path}"
      end
    end

    def run_ui
      puts "\n[Interfaccia]"
      check('Strumenti attivabili') do
        tools = [BIMSketch::Tools::WallTool.new, BIMSketch::Tools::SlabTool.new, BIMSketch::Tools::MoveOpeningTool.new,
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
        sp = model.entities.active_section_plane
        assert(sp, 'nessun piano di sezione attivo')
        n = sp.get_plane
        assert(n[2] < 0, "normale del piano di sezione verso l'alto: #{n.inspect}")
        "scena \"#{page.name}\" creata, sezione attiva a #{format('%.2f', -n[3] / n[2] * 0.0254)} m " \
          '(verifica a occhio, vedi sotto)'
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
