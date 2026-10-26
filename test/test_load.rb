# frozen_string_literal: true

# Smoke test: carica l'intera estensione con uno stub minimale dell'API
# SketchUp, per intercettare errori di caricamento (costanti, require, sintassi).
require 'minitest/autorun'

# Oggetto permissivo che accetta qualsiasi chiamata.
class Anything < BasicObject
  def initialize(*) end

  def method_missing(*)
    ::Anything.new
  end

  def respond_to_missing?(*)
    true
  end
end

$stub_calls = Hash.new(0)

module Sketchup
  class SelectionObserver; end
  class ModelObserver; end
  class AppObserver; end
  class Color < Anything; end
  class Group; end
  class ComponentInstance; end
  class Face; end
  class Edge; end
  class SectionPlane; end
  class InputPoint < Anything; end
  def self.method_missing(*) = Anything.new
  def self.respond_to_missing?(*) = true
  def self.platform = :platform_win
end

module UI
  class Command < Anything
    def initialize(*)
      $stub_calls[:command] += 1
    end
  end

  class Toolbar < Anything; end
  class HtmlDialog < Anything
    STYLE_DIALOG = 0
  end

  def self.menu(*) = Anything.new
  def self.add_context_menu_handler(*) = $stub_calls[:context] += 1
end

module Geom
  class Point3d < Anything; end
  class Vector3d < Anything; end
  class Transformation < Anything; end
  class BoundingBox < Anything; end
end

class SketchupExtension < Anything; end

X_AXIS = Y_AXIS = Z_AXIS = Anything.new
CONSTRAIN_MODIFIER_KEY = 16
GL_LINE_LOOP = 2

class Numeric
  def mm = self / 25.4
  def m = self / 0.0254
end

$loaded = {}
def file_loaded?(f) = $loaded[f]
def file_loaded(f) = ($loaded[f] = true)

$LOADED_FEATURES << 'sketchup.rb' << 'extensions.rb'

class LoadTest < Minitest::Test
  def test_extension_loads
    root = File.expand_path('../src', __dir__)
    def Sketchup.register_extension(ext, load)
      $stub_calls[:register] += 1
      require File.expand_path('../src/bimsketch/main', __dir__) if load
    end
    load File.join(root, 'bimsketch.rb')
    assert_equal 1, $stub_calls[:register]
    assert_operator $stub_calls[:command], :>=, 15
    assert_equal 1, $stub_calls[:context]
    %w[WallTool BeamTool SlabTool ColumnTool OpeningTool].each do |c|
      assert BIMSketch::Tools.const_defined?(c), c
    end
    assert BIMSketch::Dialogs::Properties.new
    BIMSketch.commands.each_key { |k| assert_kind_of Symbol, k }
    %w[properties levels schedule checker].each do |n|
      assert File.exist?(File.join(root, 'bimsketch', 'ui', 'html', "#{n}.html")), n
    end
  end
end
