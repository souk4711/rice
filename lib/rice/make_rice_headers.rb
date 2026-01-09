require 'stringio'

LINE_ENDING = "\n"
RICE_INCLUDE_REGEX = %r{#include "(.*)"}
OTHER_INCLUDE_REGEX = %r{#include <(.*)>}

RICE_HEADER_GUARD_1 = %r{#ifndef Rice__}
RICE_HEADER_GUARD_2 = %r{#define Rice__}
RICE_HEADER_GUARD_3 = %r{#endif\s*//\s*Rice__}
SHARED_METHODS_REGEX = %r{#include "((?:cpp_api\/)?shared_methods.hpp)"}

def load_file(relative_path)
  content = File.read(relative_path, mode: 'rb')

  # Special case shared_methods.hpp which if requested we want to
  # merge into the current file
  match = content.match(SHARED_METHODS_REGEX)
  if match
    shared_path = File.join(File.dirname(relative_path), match[1])
    content.gsub!(SHARED_METHODS_REGEX, File.read(shared_path, mode: 'rb'))
  end

  content
end

def sub_namespace_rice(line)
  # rice/xxxx
  if line.match?(/namespace Rice[\s\n;:]/)
    line.gsub!("namespace Rice", "namespace Rice4RubyQt6")
  elsif line.include?("Rice::")
    line.gsub!("Rice::", "Rice4RubyQt6::")
  elsif line.include?('define_module("Rice")')
    line.gsub!('define_module("Rice")', 'define_module("Rice4RubyQt6")')
  elsif line.include?('define_module("Libc")')
    line.gsub!('define_module("Libc")', 'define_module_under(define_module("Rice4RubyQt6"), "Libc")')
  elsif line.include?('define_module("Std")')
    line.gsub!('define_module("Std")', 'define_module_under(define_module("Rice4RubyQt6"), "Std")')
  end

  # test/test_xxxx
  if line.include?('Std::')
    line.gsub!("Std::", "Rice4RubyQt6::Std::")
  elsif line.include?('aModule("Std")')
    line.gsub!('aModule("Std")', 'aModule = define_module_under(define_module("Rice4RubyQt6"), "Std")')
  elsif line.include?('stdModule("Std")')
    line.gsub!('stdModule("Std")', 'stdModule = define_module_under(define_module("Rice4RubyQt6"), "Std")')
  end

  # .
  line
end

def strip_includes(content)
  content.lines.find_all do |line|
    !line.match(RICE_INCLUDE_REGEX)
  end.map do |line|
    sub_namespace_rice(line)
  end.join
end

def add_include(path, stream)
  basename = File.basename(path)
  basename_no_ext = File.basename(path, ".*")

  stream << "\n" << "// =========   #{File.basename(path)}   =========" << "\n"

  load_file(path).each_line do |line|
    if match = line.match(RICE_INCLUDE_REGEX)
      # Check for related includes, ie., Object.hpp, Object_defn.hpp and Object.ipp
      sub_include = File.basename(match[1])
      if ["#{basename_no_ext}_defn.hpp", "#{basename_no_ext}.ipp"].include?(sub_include)
        sub_include_path = File.join(File.dirname(path), match[1])
        stream << "\n" << "// ---------   #{File.basename(sub_include_path)}   ---------" << "\n"
        stream << strip_includes(load_file(sub_include_path))
      end
    elsif line.match(RICE_HEADER_GUARD_1) || line.match(RICE_HEADER_GUARD_2) || line.match(RICE_HEADER_GUARD_3)
      # Skip the header guard
    else
      # Include the line in the output
      stream << sub_namespace_rice(line)
    end
  end
end

def combine_headers(filename)
  stream = StringIO.new

  stream << "// This file is part of [rice](https://github.com/ruby-rice/rice).\n"
  stream << "//\n"
  load_file("COPYING").each_line do |line|
    stream << (line.strip.size.zero? ? "//\n" : "// #{line}")
  end
  stream << "\n"

  load_file("rice/#{filename}").each_line do |line|
    if matches = line.match(RICE_INCLUDE_REGEX)
      path = File.join("rice", matches[1])
      add_include(path, stream)
    else
      stream << line
    end
  end

  File.open("include/rice/#{filename}", 'wb') do |file|
    file << stream.string
  end
end

puts "Building rice.hpp"
combine_headers('rice.hpp')

puts "Building stl.hpp"
combine_headers('stl.hpp')

puts "Building api.hpp"
combine_headers('api.hpp')

puts "Building test files"
Dir["test/*pp"].each do |filename|
  stream = StringIO.new
  File.read(filename).each_line do |line|
    stream << sub_namespace_rice(line)
  end
  File.open(filename, "wb") do |file|
    file << stream.string
  end
end

puts "Success"
