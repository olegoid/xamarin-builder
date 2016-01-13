require 'time'
require 'pathname'

# -----------------------
# --- Constants
# -----------------------

MDTOOL_PATH = "\"/Applications/Xamarin Studio.app/Contents/MacOS/mdtool\""

CSPROJ_EXT = '.csproj'
SHPROJ_EXT = '.shproj'
SLN_EXT = '.sln'

SOLUTION = 'solution'
PROJECT = 'project'

REGEX_SOLUTION_PROJECTS = /Project\(\"(?<solution_id>[^\"]*)\"\) = \"(?<project_name>[^\"]*)\", \"(?<project_path>[^\"]*)\", \"(?<project_id>[^\"]*)\"/i
REGEX_SOLUTION_GLOBAL_SOLUTION_CONFIG_START = /GlobalSection\(SolutionConfigurationPlatforms\) = preSolution/i
REGEX_SOLUTION_GLOBAL_SOLUTION_CONFIG = /^\s*(?<config>[^|]*)\|(?<platform>[^|]*) =/i
REGEX_SOLUTION_GLOBAL_PROJECT_CONFIG_START = /GlobalSection\(ProjectConfigurationPlatforms\) = postSolution/i
REGEX_SOLUTION_GLOBAL_PROJECT_CONFIG = /(?<project_id>{[^}]*}).(?<config>(\w|\s)*)\|(?<platform>(\w|\s)*).* = (?<mapped_config>(\w|\s)*)\|(?<mapped_platform>(\w|\s)*)/i
REGEX_SOLUTION_GLOBAL_CONFIG_END = /EndGlobalSection/i

REGEX_PROJECT_GUID = /<ProjectGuid>(?<project_id>.*)<\/ProjectGuid>/i
REGEX_PROJECT_OUTPUT_TYPE = /<OutputType>(?<output_type>.*)<\/OutputType>/i
REGEX_PROJECT_ASSEMBLY_NAME = /<AssemblyName>(?<assembly_name>.*)<\/AssemblyName>/i
REGEX_PROJECT_PROPERTY_GROUP_WITH_CONDITION = /<PropertyGroup Condition=\" '\$\(Configuration\)\|\$\(Platform\)' == '(?<config>(\w|\s)*)\|(?<platform>(\w|\s)*)' \">/i
REGEX_PROJECT_PROPERTY_GROUP_END = /<\/PropertyGroup>/i
REGEX_PROJECT_OUTPUT_PATH = /<OutputPath>(?<output_path>.*)<\/OutputPath>/i
REGEX_PROJECT_IPA_PACKAGE = /<IpaPackageName>/i
REGEX_PROJECT_BUILD_IPA = /<BuildIpa>true<\/BuildIpa>/i
REGEX_PROJECT_REFERENCE_XAMARIN_IOS = /Include="Xamarin.iOS"/i
REGEX_PROJECT_REFERENCE_XAMARIN_ANDROID = /Include="Mono.Android"/i
REGEX_PROJECT_REFERENCE_XAMARIN_UITEST = /Include="Xamarin.UITest"/i
REGEX_PROJECT_MTOUCH_ARCH = /<MtouchArch>(?<arch>.*)<\/MtouchArch>/

REGEX_ARCHIVE_DATE_TIME = /\s(.*[AM]|[PM]).*\./i

class Analyzer
  def analyze(path)
    @path = path

    case type
      when SOLUTION
        analyze_solution(@path)
      when PROJECT
    end

    @solution[:projects].each do |project|
      analyze_project(project)
    end
  end

  def inspect
    puts "-- analyze: #{@path}"
    puts
    puts @solution
  end

  def build_command(config, platform)
    configuration = "#{config}|#{platform}"

    @solution[:projects].each do |project|
      project_configuration = project[:mappings][configuration]

      case project[:api]
        when 'ios'
          next unless project[:output_type].eql?('exe')
        else
          next
      end

      raise "No configuration mapping found for (#{configuration}) in project #{project[:name]}" unless project_configuration

      archs = project[:configs][project_configuration][:mtouch_arch]
      generate_archive = archs.select { |x| x.downcase.start_with? 'arm' }.count == archs.count

      return [
          MDTOOL_PATH,
          generate_archive ? 'archive' : 'build',
          "\"-c:#{configuration}\"",
          @solution[:path],
          "-p:#{project[:name]}"
      ].join(' ')

      # TODO /Library/Frameworks/Mono.framework/Commands/xbuild /t:SignAndroidPackage /p:Configuration=Release /path/to/android.csproj
    end
  end

  def output_hash(config, platform)
    outputs_hash = {}

    configuration = "#{config}|#{platform}"

    @solution[:projects].each do |project|
      project_configuration = project[:mappings][configuration]

      case project[:api]
        when 'ios'
          next unless project[:output_type].eql?('exe')

          raise "No configuration mapping found for (#{configuration}) in project #{project[:name]}" unless project_configuration

          assembly_name = project[:assembly_name]

          archs = project[:configs][project_configuration][:mtouch_arch]
          generate_archive = archs.select { |x| x.downcase.start_with? 'arm' }.count == archs.count

          project_path = project[:path]
          project_dir = File.dirname(project_path)
          rel_output_dir = project[:configs][project_configuration][:output_path]
          full_output_dir = File.join(project_dir, rel_output_dir)

          if generate_archive
            full_output_path = latest_archive_path(assembly_name)

            outputs_hash[:xcarchive] = full_output_path
          else
            full_output_path = export_artifact(assembly_name, full_output_dir, '.app')

            outputs_hash[:app] = full_output_path
          end
        else
          next
      end
    end

    outputs_hash
  end

  private

  def type
    return SOLUTION if @path.downcase.end_with? SLN_EXT
    return PROJECT if @path.downcase.end_with? CSPROJ_EXT
    raise "unsupported type for path: #{@path}"
  end

  def analyze_solution(solution_path)
    @solution = {
        path: solution_path,
        base_dir: File.dirname(@path)
    }

    parse_solution_configs = false
    parse_project_configs = false

    File.open(@solution[:path]).each do |line|
      # Project
      match = line.match(REGEX_SOLUTION_PROJECTS)
      if match != nil && match.captures != nil && match.captures.count == 4
        # Skip files that are directories or doesn't exist
        project_path = File.join([@solution[:base_dir]].concat(match.captures[2].split('\\')))

        if File.file? project_path
          @solution[:id] = match.captures[0]
          (@solution[:projects] ||= []) << {
              name: match.captures[1],
              path: project_path,
              id: match.captures[3],
          }
        else
          puts "Warning: Skipping #{project_path}: directory or not found on file system"
        end
      end

      # Solution configs
      match = line.match(REGEX_SOLUTION_GLOBAL_CONFIG_END)
      parse_solution_configs = false if match != nil

      if parse_solution_configs
        match = line.match(REGEX_SOLUTION_GLOBAL_SOLUTION_CONFIG)
        if match != nil && match.captures != nil && match.captures.count == 2
          (@solution[:configs] ||= []) << "#{match.captures[0]}|#{match.captures[1].delete(' ')}"
        end
      end

      match = line.match(REGEX_SOLUTION_GLOBAL_SOLUTION_CONFIG_START)
      parse_solution_configs = true if match != nil

      # Project configs
      match = line.match(REGEX_SOLUTION_GLOBAL_CONFIG_END)
      parse_project_configs = false if match != nil

      if parse_project_configs
        match = line.match(REGEX_SOLUTION_GLOBAL_PROJECT_CONFIG)
        if match != nil && match.captures != nil && match.captures.count == 5
          project_id = match.captures[0]

          project = project_with_id(project_id)
          (project[:mappings] ||= {})["#{match.captures[1]}|#{match.captures[2].delete(' ')}"] = "#{match.captures[3]}|#{match.captures[4].strip.delete(' ')}"
        end
      end

      match = line.match(REGEX_SOLUTION_GLOBAL_PROJECT_CONFIG_START)
      parse_project_configs = true if match != nil
    end
  end

  def analyze_project(project)
    project_config = nil

    File.open(project[:path]).each do |line|
      # Guid
      match = line.match(REGEX_PROJECT_GUID)
      if match != nil && match.captures != nil && match.captures.count == 1
        unless project[:id].eql? match.captures[0]
          raise "Invalid id found in project: #{project[:path]}"
        end
      end

      # output type
      match = line.match(REGEX_PROJECT_OUTPUT_TYPE)
      if match != nil && match.captures != nil && match.captures.count == 1
        project[:output_type] = match.captures[0].downcase
      end

      # assembly name
      match = line.match(REGEX_PROJECT_ASSEMBLY_NAME)
      if match != nil && match.captures != nil && match.captures.count == 1
        project[:assembly_name] = match.captures[0]
      end

      # PropertyGroup with condition
      match = line.match(REGEX_PROJECT_PROPERTY_GROUP_END)
      project_config = nil if match

      if project_config != nil
        match = line.match(REGEX_PROJECT_OUTPUT_PATH)
        if match != nil && match.captures != nil && match.captures.count == 1
          project[:configs][project_config][:output_path] = File.join(match.captures[0].split('\\'))
        end

        match = line.match(REGEX_PROJECT_MTOUCH_ARCH)
        if match != nil && match.captures != nil && match.captures.count == 1
          project[:configs][project_config][:mtouch_arch] = match.captures[0].split(',').collect { |x| x.strip || x }
        end

        match = line.match(REGEX_PROJECT_IPA_PACKAGE)
        project[:configs][project_config][:ipa_package] = true if match != nil

        match = line.match(REGEX_PROJECT_BUILD_IPA)
        project[:configs][project_config][:build_ipa] = true if match != nil
      end

      match = line.match(REGEX_PROJECT_PROPERTY_GROUP_WITH_CONDITION)
      if match != nil && match.captures != nil && match.captures.count == 2
        project_config = "#{match.captures[0]}|#{match.captures[1].delete(' ')}"

        (project[:configs] ||= {})[project_config] = {}
      end

      # API
      match = line.match(REGEX_PROJECT_REFERENCE_XAMARIN_IOS)
      project[:api] = 'ios' if match != nil

      match = line.match(REGEX_PROJECT_REFERENCE_XAMARIN_ANDROID)
      project[:api] = 'android' if match != nil

      match = line.match(REGEX_PROJECT_REFERENCE_XAMARIN_UITEST)
      project[:api] = 'uitest' if match != nil
    end
  end

  def project_with_id(id)
    return nil unless @solution

    @solution[:projects].each do |project|
      return project if project[:id].eql? id
    end
  end

  def export_artifact(assembly_name, output_path, extension)
    artifact = Dir[File.join(output_path, "#{assembly_name}#{extension}")].first
    return nil unless artifact

    full_path = Pathname.new(artifact).realpath.to_s
    return nil unless full_path
    return nil unless File.exist? full_path

    full_path
  end

  def latest_archive_path(assembly_name)
    home_dir = ENV['HOME']
    default_archives_path = File.join(home_dir, 'Library/Developer/Xcode/Archives')
    raise "No default Xcode archive path found at #{default_archives_path}" unless File.exist? default_archives_path

    latest_archive = nil
    latest_archive_date = nil

    archives = Dir[File.join(default_archives_path, "**/#{assembly_name}*.xcarchive")]
    archives.each do |archive_path|
      match = archive_path.match(REGEX_ARCHIVE_DATE_TIME)

      if match != nil && match.captures != nil && match.captures.size == 1
        date = DateTime.strptime(match.captures[0], '%m-%d-%y %l.%M %p')

        if (latest_archive_date ||= date) < date
          latest_archive_date = date
          latest_archive = archive_path
        end
      end
    end

    latest_archive
  end
end
