# frozen_string_literal: true
#
# BIMSketch - estensione BIM per SketchUp.
# File di caricamento: va copiato nella cartella Plugins di SketchUp insieme
# alla cartella "bimsketch" (oppure installato tramite il pacchetto .rbz).

require 'sketchup.rb'
require 'extensions.rb'

module BIMSketch
  dir = File.dirname(__FILE__)
  dir = dir.dup.force_encoding('UTF-8') if dir.respond_to?(:force_encoding)
  PLUGIN_ROOT = File.join(dir, 'bimsketch')

  require File.join(PLUGIN_ROOT, 'version')

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new(EXTENSION_NAME, File.join(PLUGIN_ROOT, 'main'))
    ext.description = 'Trasforma SketchUp in uno strumento BIM: elementi edilizi ' \
                      'parametrici, classificazione IFC, livelli, proprietà, ' \
                      'abachi delle quantità ed esportazione IFC4.'
    ext.version = VERSION
    ext.creator = 'BIMSketch'
    ext.copyright = '2026 BIMSketch - Licenza MIT'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
