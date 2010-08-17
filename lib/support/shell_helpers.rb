def which cmd_name, &block
  result = shell "which #{cmd_name}", &block
  result unless result.nil? || result["no #{cmd_name} in"]
end

require 'fileutils'
def in_dir dir, opts = {}, &block
  if dir.nil?
    yield Dir.pwd.p
  else
    path = dir.p
    path.mkdir if opts[:create] unless path.exists?
    if Dir.pwd == path
      yield path
    else
      Dir.chdir path do
        debug "in dir #{dir} (#{path})" do
          yield path
        end
      end
    end
  end
end

def in_build_dir path = '', &block
  # TODO This shouldn't be here forever
  # Rename ~/.babushka/src to ~/.babushka/build
  if (Babushka::WorkingPrefix / 'src').p.exists? && !Babushka::BuildPrefix.p.exists?
    shell "mv ~/.babushka/src ~/.babushka/build"
  end
  in_dir Babushka::BuildPrefix / path, :create => true, &block
end

def in_download_dir path = '', &block
  in_dir Babushka::DownloadPrefix / path, :create => true, &block
end

def cmd_dir cmd_name
  which("#{cmd_name}") {|shell|
    File.dirname shell.stdout if shell.ok?
  }
end

def log_block message, opts = {}, &block
  log "#{message}...", :newline => false
  returning block.call do |result|
    log result ? ' done.' : ' failed', :as => (result ? nil : :error), :indentation => false
  end
end

def log_shell message, cmd, opts = {}, &block
  log_block message do
    opts.delete(:sudo) ? sudo(cmd, opts.merge(:spinner => true), &block) : shell(cmd, opts.merge(:spinner => true), &block)
  end
end

def log_shell_with_a_block_to_scan_stdout_for_apps_that_have_broken_return_values message, cmd, opts = {}, &block
  log_block message do
    send opts.delete(:sudo) ? :sudo : :shell, cmd, opts.merge(:failable => true), &block
  end
end

def rake cmd, &block
  sudo "rake #{cmd} RAILS_ENV=#{var :rails_env}", :as => var(:username), &block
end

def rails_rake cmd, &block
  in_dir var(:rails_root) do
    rake cmd, &block
  end
end

def check_file file_name, method_name
  returning File.send(method_name, file_name) do |result|
    log_error "#{file_name} failed #{method_name.to_s.sub(/[?!]$/, '')} check." unless result
  end
end

def grep pattern, file
  if (path = file.p).exists?
    output = if pattern.is_a? String
      path.readlines.select {|l| l[pattern] }
    elsif pattern.is_a? Regexp
      path.readlines.grep pattern
    end
    output unless output.empty?
  end
end

def change_line line, replacement, filename
  path = filename.p

  log "Patching #{path}"
  sudo "cat > #{path}", :as => path.owner, :input => path.readlines.map {|l|
    l.gsub /^(\s*)(#{Regexp.escape(line)})/, "\\1# #{edited_by_babushka}\n\\1# was: \\2\n\\1#{replacement}"
  }
end

def insert_into_file insert_before, path, lines, opts = {}
  opts = {:comment_char => '#', :insert_after => nil}.merge(opts)
  nlines = lines.split("\n").length
  before, after = path.p.readlines.cut {|l| l.strip == insert_before.strip }

  log "Patching #{path}"
  if after.empty? || (opts[:insert_after] && before.last.strip != opts[:insert_after].strip)
    log_error "Couldn't find the spot to write to in #{path}."
  else
    shell "cat > #{path}", :as => path.owner, :sudo => !File.writable?(path), :input => [
      before,
      added_by_babushka(nlines).start_with(opts[:comment_char] + ' ').end_with("\n"),
      lines.end_with("\n"),
      after
    ].join
  end
end

def change_with_sed keyword, from, to, file
  # Remove the incorrect setting if it's there
  shell("#{sed} -ri 's/^#{keyword}\s+#{from}//' #{file}", :sudo => !File.writable?(file))
  # Add the correct setting unless it's already there
  grep(/^#{keyword}\s+#{to}/, file) or shell("echo '#{keyword} #{to}' >> #{file}", :sudo => !File.writable?(file))
end

def sed
  host.linux? ? 'sed' : 'gsed'
end

def append_to_file text, file, opts = {}
  if failable_shell("grep '^#{text}' '#{file}'").stdout.empty?
    shell %Q{echo "# #{added_by_babushka(text.split("\n").length)}\n#{text.gsub('"', '\"')}" >> #{file}}, opts
  end
end

def _by_babushka
  "by babushka-#{Babushka::VERSION} at #{Time.now}"
end
def generated_by_babushka
  "Generated #{_by_babushka}"
end
def edited_by_babushka
  "This line edited #{_by_babushka}"
end
def added_by_babushka nlines
  if nlines == 1
    "This line added #{_by_babushka}"
  else
    "These #{nlines} lines added #{_by_babushka}"
  end
end

def read_file filename
  path = filename.p
  path.read.chomp if path.exists?
end

def babushka_config? path
  if !path.p.exists?
    unmet "the config hasn't been generated yet"
  elsif !grep(/Generated by babushka/, path)
    unmet "the config needs to be regenerated"
  else
    true
  end
end

def git_repo? path
  real_path = path.p
  in_dir(real_path) {
    !shell("git rev-parse --git-dir").blank?
  } if File.exists?(real_path)
end

def confirm message, opts = {}, &block
  prompter = (!opts[:always_ask] && respond_to?(:var)) ? :var : :prompt_for_value
  answer = send(prompter, message,
    :message => message,
    :confirmation => true,
    :default => (opts[:default] || 'y')
  ).starts_with?('y')

  if block.nil?
    answer
  elsif answer
    block.call
  elsif opts[:otherwise]
    log opts[:otherwise]
  end
end

require 'yaml'
def yaml path
  YAML.load_file path.p
end

def render_erb erb, opts = {}
  if (path = erb_path_for(erb)).nil?
    log_error "If you use #render_erb within a dynamically defined dep, you have to give the full path to the erb template."
  elsif !File.exists?(path) && !opts[:optional]
    log_error "Couldn't find erb to render at #{path}."
  elsif File.exists?(path)
    require 'erb'
    debug ERB.new(IO.read(path)).result(binding)
    returning shell("cat > #{opts[:to]}",
      :input => ERB.new(IO.read(path)).result(binding),
      :sudo => opts[:sudo]
    ) do |result|
      if result
        log "Rendered #{opts[:to]}."
        sudo "chmod #{opts[:perms]} '#{opts[:to]}'" unless opts[:perms].nil?
      else
        log_error "Couldn't render #{opts[:to]}."
      end
    end
  end
end

def erb_path_for erb
  if erb.to_s.starts_with? '/'
    erb # absolute path
  elsif load_path
    File.dirname(load_path) / erb # directory this dep is in, plus relative path
  end
end

def log_and_open message, url
  log "#{message} Hit Enter to open the download page.", :newline => false
  read_from_prompt ' '
  shell "open #{url}"
end

def mysql cmd, username = 'root', include_password = true
  password_segment = "--password='#{var :db_password}'" if include_password
  shell "echo \"#{cmd.gsub('"', '\"').end_with(';')}\" | mysql -u #{username} #{password_segment}"
end
