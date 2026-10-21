# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.warning = false
end

desc 'Crea il pacchetto installabile dist/bimsketch-<versione>.rbz'
task :build do
  require_relative 'src/bimsketch/version'
  out = File.expand_path("dist/bimsketch-#{BIMSketch::VERSION}.rbz", __dir__)
  mkdir_p File.dirname(out)
  rm_f out
  Dir.chdir('src') { sh "zip -qr -X #{out} bimsketch.rb bimsketch -x '*.DS_Store'" }
  puts "Creato #{out}"
end

task default: :test
