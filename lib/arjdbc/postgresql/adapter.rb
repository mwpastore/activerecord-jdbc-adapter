module ActiveRecord::ConnectionAdapters
  PostgreSQLAdapter = Class.new(AbstractAdapter) unless const_defined?(:PostgreSQLAdapter)
end

module ::ArJdbc
  module PostgreSQL
    def self.extended(mod)
      (class << mod; self; end).class_eval do
        alias_chained_method :columns, :query_cache, :pg_columns
      end
    end

    def self.column_selector
      [/postgre/i, lambda {|cfg,col| col.extend(::ArJdbc::PostgreSQL::Column)}]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::PostgresJdbcConnection
    end

    # column behavior based on postgresql_adapter in rails project
    # https://github.com/rails/rails/blob/3-1-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L41
    module Column
      def self.included(base)
        class << base
          attr_accessor :money_precision
          def string_to_time(string)
            return string unless String === string

            case string
            when 'infinity' then 1.0 / 0.0
            when '-infinity' then -1.0 / 0.0
            else
              super
            end
          end
        end
      end

      private
      # Extracts the value from a Postgresql column default definition
      def default_value(default)
        case default
          # This is a performance optimization for Ruby 1.9.2 in development.
          # If the value is nil, we return nil straight away without checking
          # the regular expressions. If we check each regular expression,
          # Regexp#=== will call NilClass#to_str, which will trigger
          # method_missing (defined by whiny nil in ActiveSupport) which
          # makes this method very very slow.
        when NilClass
          nil
          # Numeric types
        when /\A\(?(-?\d+(\.\d*)?\)?)\z/
          $1
          # Character types
        when /\A'(.*)'::(?:character varying|bpchar|text)\z/m
          $1
          # Character types (8.1 formatting)
        when /\AE'(.*)'::(?:character varying|bpchar|text)\z/m
          $1.gsub(/\\(\d\d\d)/) { $1.oct.chr }
          # Binary data types
        when /\A'(.*)'::bytea\z/m
          $1
          # Date/time types
        when /\A'(.+)'::(?:time(?:stamp)? with(?:out)? time zone|date)\z/
          $1
        when /\A'(.*)'::interval\z/
          $1
          # Boolean type
        when 'true'
          true
        when 'false'
          false
          # Geometric types
        when /\A'(.*)'::(?:point|line|lseg|box|"?path"?|polygon|circle)\z/
          $1
          # Network address types
        when /\A'(.*)'::(?:cidr|inet|macaddr)\z/
          $1
          # Bit string types
        when /\AB'(.*)'::"?bit(?: varying)?"?\z/
          $1
          # XML type
        when /\A'(.*)'::xml\z/m
          $1
          # Arrays
        when /\A'(.*)'::"?\D+"?\[\]\z/
          $1
          # Object identifier types
        when /\A-?\d+\z/
          $1
        else
          # Anything else is blank, some user type, or some function
          # and we can't know the value of that, so return nil.
          nil
        end
      end

      def extract_limit(sql_type)
        case sql_type
        when /^bigin/i then 8
        when /^smallint/i then 2
        else super
        end
      end

      # Extracts the scale from PostgreSQL-specific data types.
      def extract_scale(sql_type)
        # Money type has a fixed scale of 2.
        sql_type =~ /^money/ ? 2 : super
      end

      # Extracts the precision from PostgreSQL-specific data types.
      def extract_precision(sql_type)
        if sql_type == 'money'
          self.class.money_precision
        else
          super
        end
      end

      # Maps PostgreSQL-specific data types to logical Rails types.
      def simplified_type(field_type)
        case field_type
          # Numeric and monetary types
        when /^(?:real|double precision)$/ then :float
          # Monetary types
        when 'money' then :decimal
          # Character types
        when /^(?:character varying|bpchar)(?:\(\d+\))?$/ then :string
          # Binary data types
        when 'bytea' then :binary
          # Date/time types
        when /^timestamp with(?:out)? time zone$/ then :datetime
        when 'interval' then :string
          # Geometric types
        when /^(?:point|line|lseg|box|"?path"?|polygon|circle)$/ then :string
          # Network address types
        when /^(?:cidr|inet|macaddr)$/ then :string
          # Bit strings
        when /^bit(?: varying)?(?:\(\d+\))?$/ then :string
          # XML type
        when 'xml' then :xml
          # tsvector type
        when 'tsvector' then :tsvector
          # Arrays
        when /^\D+\[\]$/ then :string
          # Object identifier types
        when 'oid' then :integer
          # UUID type
        when 'uuid' then :string
          # Small and big integer types
        when /^(?:small|big)int$/ then :integer
          # Pass through all types that are not specific to PostgreSQL.
        else
          super
        end
      end
    end

    def modify_types(tp)
      tp[:primary_key] = "serial primary key"
      tp[:string][:limit] = 255
      tp[:integer][:limit] = nil
      tp[:boolean] = { :name => "boolean" }
      tp[:float] = { :name => "float" }
      tp[:text] = { :name => "text" }
      tp[:datetime] = { :name => "timestamp" }
      tp[:timestamp] = { :name => "timestamp" }
      tp[:time] = { :name => "time" }
      tp[:date] = { :name => "date" }
      tp[:decimal] = { :name => "decimal" }
      tp
    end

    def adapter_name #:nodoc:
      'PostgreSQL'
    end

    def self.arel2_visitors(config)
      {}.tap {|v| %w(postgresql pg jdbcpostgresql).each {|a| v[a] = ::Arel::Visitors::PostgreSQL } }
    end

    def postgresql_version
      @postgresql_version ||=
        begin
          value = select_value('SELECT version()')
          if value =~ /PostgreSQL (\d+)\.(\d+)\.(\d+)/
            ($1.to_i * 10000) + ($2.to_i * 100) + $3.to_i
          else
            0
          end
        end
    end

    # Does PostgreSQL support migrations?
    def supports_migrations?
      true
    end

    # Does PostgreSQL support standard conforming strings?
    def supports_standard_conforming_strings?
      # Temporarily set the client message level above error to prevent unintentional
      # error messages in the logs when working on a PostgreSQL database server that
      # does not support standard conforming strings.
      client_min_messages_old = client_min_messages
      self.client_min_messages = 'panic'

      # postgres-pr does not raise an exception when client_min_messages is set higher
      # than error and "SHOW standard_conforming_strings" fails, but returns an empty
      # PGresult instead.
      has_support = select('SHOW standard_conforming_strings').to_a[0][0] rescue false
      self.client_min_messages = client_min_messages_old
      has_support
    end

    def supports_insert_with_returning?
      postgresql_version >= 80200
    end

    def supports_ddl_transactions?
      true
    end

    def supports_savepoints?
      true
    end

    def supports_count_distinct? #:nodoc:
      false
    end

    def create_savepoint
      execute("SAVEPOINT #{current_savepoint_name}")
    end

    def rollback_to_savepoint
      execute("ROLLBACK TO SAVEPOINT #{current_savepoint_name}")
    end

    def release_savepoint
      execute("RELEASE SAVEPOINT #{current_savepoint_name}")
    end

    # Returns the configured supported identifier length supported by PostgreSQL,
    # or report the default of 63 on PostgreSQL 7.x.
    def table_alias_length
      @table_alias_length ||= (postgresql_version >= 80000 ? select_one('SHOW max_identifier_length')['max_identifier_length'].to_i : 63)
    end

    def default_sequence_name(table_name, pk = nil)
      default_pk, default_seq = pk_and_sequence_for(table_name)
      default_seq || "#{table_name}_#{pk || default_pk || 'id'}_seq"
    end

    # Resets sequence to the max value of the table's pk if present.
    def reset_pk_sequence!(table, pk = nil, sequence = nil) #:nodoc:
      unless pk and sequence
        default_pk, default_sequence = pk_and_sequence_for(table)
        pk ||= default_pk
        sequence ||= default_sequence
      end
      if pk
        if sequence
          quoted_sequence = quote_column_name(sequence)

          select_value <<-end_sql, 'Reset sequence'
              SELECT setval('#{quoted_sequence}', (SELECT COALESCE(MAX(#{quote_column_name pk})+(SELECT increment_by FROM #{quoted_sequence}), (SELECT min_value FROM #{quoted_sequence})) FROM #{quote_table_name(table)}), false)
            end_sql
        else
          @logger.warn "#{table} has primary key #{pk} with no default sequence" if @logger
        end
      end
    end

    # Find a table's primary key and sequence.
    def pk_and_sequence_for(table) #:nodoc:
      # First try looking for a sequence with a dependency on the
      # given table's primary key.
      result = select(<<-end_sql, 'PK and serial sequence')[0]
          SELECT attr.attname, seq.relname
          FROM pg_class      seq,
               pg_attribute  attr,
               pg_depend     dep,
               pg_namespace  name,
               pg_constraint cons
          WHERE seq.oid           = dep.objid
            AND seq.relkind       = 'S'
            AND attr.attrelid     = dep.refobjid
            AND attr.attnum       = dep.refobjsubid
            AND attr.attrelid     = cons.conrelid
            AND attr.attnum       = cons.conkey[1]
            AND cons.contype      = 'p'
            AND dep.refobjid      = '#{quote_table_name(table)}'::regclass
        end_sql

      if result.nil? or result.empty?
        # If that fails, try parsing the primary key's default value.
        # Support the 7.x and 8.0 nextval('foo'::text) as well as
        # the 8.1+ nextval('foo'::regclass).
        result = select(<<-end_sql, 'PK and custom sequence')[0]
            SELECT attr.attname,
              CASE
                WHEN split_part(def.adsrc, '''', 2) ~ '.' THEN
                  substr(split_part(def.adsrc, '''', 2),
                         strpos(split_part(def.adsrc, '''', 2), '.')+1)
                ELSE split_part(def.adsrc, '''', 2)
              END as relname
            FROM pg_class       t
            JOIN pg_attribute   attr ON (t.oid = attrelid)
            JOIN pg_attrdef     def  ON (adrelid = attrelid AND adnum = attnum)
            JOIN pg_constraint  cons ON (conrelid = adrelid AND adnum = conkey[1])
            WHERE t.oid = '#{quote_table_name(table)}'::regclass
              AND cons.contype = 'p'
              AND def.adsrc ~* 'nextval'
          end_sql
      end

      [result["attname"], result["relname"]]
    rescue
      nil
    end

    # Returns just a table's primary key
    def primary_key(table)
      row = exec_query(<<-end_sql, 'SCHEMA', [[nil, table]]).rows.first
          SELECT DISTINCT(attr.attname)
          FROM pg_attribute attr
          INNER JOIN pg_depend dep ON attr.attrelid = dep.refobjid AND attr.attnum = dep.refobjsubid
          INNER JOIN pg_constraint cons ON attr.attrelid = cons.conrelid AND attr.attnum = cons.conkey[1]
          WHERE cons.contype = 'p'
            AND dep.refobjid = $1::regclass
        end_sql

      row && row.first
    end

    # taken from rails postgresql adapter
    # https://github.com/gfmurphy/rails/blob/master/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L611
    def sql_for_insert(sql, pk, id_value, sequence_name, binds)
      unless pk
        table_ref = extract_table_ref_from_insert_sql(sql)
        pk = primary_key(table_ref) if table_ref
      end

      sql = "#{sql} RETURNING #{quote_column_name(pk)}" if pk

      [sql, binds]
    end

    def pg_columns(table_name, name=nil)
      column_definitions(table_name).map do |row|
        ::ActiveRecord::ConnectionAdapters::PostgreSQLColumn.new(
          row["column_name"], row["column_default"], row["column_type"],
          row["column_not_null"] == "f")
      end
    end

    # Sets the maximum number columns postgres has, default 32
    def multi_column_index_limit=(limit)
      @multi_column_index_limit = limit
    end

    # Gets the maximum number columns postgres has, default 32
    def multi_column_index_limit
      defined?(@multi_column_index_limit) && @multi_column_index_limit || 32
    end

    # Based on postgresql_adapter.rb
    def indexes(table_name, name = nil)
      schema_search_path = @config[:schema_search_path] || select_rows('SHOW search_path')[0][0]
      schemas = schema_search_path.split(/,/).map { |p| quote(p) }.join(',')
      result = select_rows(<<-SQL, name)
        SELECT i.relname, d.indisunique, a.attname, a.attnum, d.indkey
          FROM pg_class t, pg_class i, pg_index d, pg_attribute a,
          generate_series(0,#{multi_column_index_limit - 1}) AS s(i)
         WHERE i.relkind = 'i'
           AND d.indexrelid = i.oid
           AND d.indisprimary = 'f'
           AND t.oid = d.indrelid
           AND t.relname = '#{table_name}'
           AND i.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname IN (#{schemas}) )
           AND a.attrelid = t.oid
           AND d.indkey[s.i]=a.attnum
        ORDER BY i.relname
      SQL

      current_index = nil
      indexes = []

      insertion_order = []
      index_order = nil

      result.each do |row|
        if current_index != row[0]

          (index_order = row[4].split(' ')).each_with_index{ |v, i| index_order[i] = v.to_i }
          indexes << ::ActiveRecord::ConnectionAdapters::IndexDefinition.new(table_name, row[0], row[1] == "t", [])
          current_index = row[0]
        end
        insertion_order = row[3]
        ind = index_order.index(insertion_order)
        indexes.last.columns[ind] = row[2]
      end

      indexes
    end

    # take id from result of insert query
    def last_inserted_id(result)
      Hash[Array(*result)].fetch("id") { result }
    end

    def last_insert_id(table, sequence_name)
      Integer(select_value("SELECT currval('#{sequence_name}')"))
    end

    def recreate_database(name)
      drop_database(name)
      create_database(name)
    end

    def create_database(name, options = {})
      execute "CREATE DATABASE \"#{name}\" ENCODING='#{options[:encoding] || 'utf8'}'"
    end

    def drop_database(name)
      execute "DROP DATABASE IF EXISTS \"#{name}\""
    end

    def create_schema(schema_name, pg_username)
      execute("CREATE SCHEMA \"#{schema_name}\" AUTHORIZATION \"#{pg_username}\"")
    end

    def drop_schema(schema_name)
      execute("DROP SCHEMA \"#{schema_name}\"")
    end

    def all_schemas
      select('select nspname from pg_namespace').map {|r| r["nspname"] }
    end

    def primary_key(table)
      pk_and_sequence = pk_and_sequence_for(table)
      pk_and_sequence && pk_and_sequence.first
    end

    def structure_dump
      database = @config[:database]
      if database.nil?
        if @config[:url] =~ /\/([^\/]*)$/
          database = $1
        else
          raise "Could not figure out what database this url is for #{@config["url"]}"
        end
      end

      ENV['PGHOST']     = @config[:host] if @config[:host]
      ENV['PGPORT']     = @config[:port].to_s if @config[:port]
      ENV['PGPASSWORD'] = @config[:password].to_s if @config[:password]
      search_path = @config[:schema_search_path]
      search_path = "--schema=#{search_path}" if search_path

      @connection.connection.close
      begin
        definition = `pg_dump -i -U "#{@config[:username]}" -s -x -O #{search_path} #{database}`
        raise "Error dumping database" if $?.exitstatus == 1

        # need to patch away any references to SQL_ASCII as it breaks the JDBC driver
        definition.gsub(/SQL_ASCII/, 'UNICODE')
      ensure
        reconnect!
      end
    end

    # SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
    #
    # PostgreSQL requires the ORDER BY columns in the select list for distinct queries, and
    # requires that the ORDER BY include the distinct column.
    #
    #   distinct("posts.id", "posts.created_at desc")
    def distinct(columns, orders) #:nodoc:
      return "DISTINCT #{columns}" if orders.empty?

      # Construct a clean list of column names from the ORDER BY clause, removing
      # any ASC/DESC modifiers
      order_columns = orders.collect { |s| s.gsub(/\s+(ASC|DESC)\s*/i, '') }.
        reject(&:blank?)
      order_columns = order_columns.
        zip((0...order_columns.size).to_a).map { |s,i| "#{s} AS alias_#{i}" }

      "DISTINCT #{columns}, #{order_columns * ', '}"
    end

    # ORDER BY clause for the passed order option.
    #
    # PostgreSQL does not allow arbitrary ordering when using DISTINCT ON, so we work around this
    # by wrapping the sql as a sub-select and ordering in that query.
    def add_order_by_for_association_limiting!(sql, options)
      return sql if options[:order].blank?

      order = options[:order].split(',').collect { |s| s.strip }.reject(&:blank?)
      order.map! { |s| 'DESC' if s =~ /\bdesc$/i }
      order = order.zip((0...order.size).to_a).map { |s,i| "id_list.alias_#{i} #{s}" }.join(', ')

      sql.replace "SELECT * FROM (#{sql}) AS id_list ORDER BY #{order}"
    end

    # from postgres_adapter.rb in rails project
    # https://github.com/rails/rails/blob/3-1-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L412
    # Quotes PostgreSQL-specific data types for SQL input.
    def quote(value, column = nil) #:nodoc:
      return super unless column

      case value
      when Float
        return super unless value.infinite? && column.type == :datetime
        "'#{value.to_s.downcase}'"
      when Numeric
        return super unless column.sql_type == 'money'
        # Not truly string input, so doesn't require (or allow) escape string syntax.
        "'#{value}'"
      when String
        case column.sql_type
        when 'bytea' then "'#{escape_bytea(value)}'"
        when 'xml'   then "xml '#{quote_string(value)}'"
        when /^bit/
          case value
          when /^[01]*$/      then "B'#{value}'" # Bit-string notation
          when /^[0-9A-F]*$/i then "X'#{value}'" # Hexadecimal notation
          end
        else
          super
        end
      else
        super
      end
    end

    def escape_bytea(s)
      if s
        result = ''
        s.each_byte { |c| result << sprintf('\\\\%03o', c) }
        result
      end
    end

    def quote_table_name(name)
      schema, name_part = extract_pg_identifier_from_name(name.to_s)

      unless name_part
        quote_column_name(schema)
      else
        table_name, name_part = extract_pg_identifier_from_name(name_part)
        "#{quote_column_name(schema)}.#{quote_column_name(table_name)}"
      end
    end

    def quote_column_name(name)
      %("#{name.to_s.gsub("\"", "\"\"")}")
    end

    def quoted_date(value) #:nodoc:
      if value.acts_like?(:time) && value.respond_to?(:usec)
        "#{super}.#{sprintf("%06d", value.usec)}"
      else
        super
      end
    end

    def disable_referential_integrity(&block) #:nodoc:
      execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name)} DISABLE TRIGGER ALL" }.join(";"))
      yield
    ensure
      execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name)} ENABLE TRIGGER ALL" }.join(";"))
    end

    def rename_table(name, new_name)
      execute "ALTER TABLE #{name} RENAME TO #{new_name}"
    end

    # Adds a new column to the named table.
    # See TableDefinition#column for details of the options you can use.
    def add_column(table_name, column_name, type, options = {})
      default = options[:default]
      notnull = options[:null] == false

      # Add the column.
      execute("ALTER TABLE #{quote_table_name(table_name)} ADD COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}")

      change_column_default(table_name, column_name, default) if options_include_default?(options)
      change_column_null(table_name, column_name, false, default) if notnull
    end

    # Changes the column of a table.
    def change_column(table_name, column_name, type, options = {})
      quoted_table_name = quote_table_name(table_name)

      begin
        execute "ALTER TABLE #{quoted_table_name} ALTER COLUMN #{quote_column_name(column_name)} TYPE #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      rescue ActiveRecord::StatementInvalid => e
        raise e if postgresql_version > 80000
        # This is PostgreSQL 7.x, so we have to use a more arcane way of doing it.
        begin
          begin_db_transaction
          tmp_column_name = "#{column_name}_ar_tmp"
          add_column(table_name, tmp_column_name, type, options)
          execute "UPDATE #{quoted_table_name} SET #{quote_column_name(tmp_column_name)} = CAST(#{quote_column_name(column_name)} AS #{type_to_sql(type, options[:limit], options[:precision], options[:scale])})"
          remove_column(table_name, column_name)
          rename_column(table_name, tmp_column_name, column_name)
          commit_db_transaction
        rescue
          rollback_db_transaction
        end
      end

      change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
      change_column_null(table_name, column_name, options[:null], options[:default]) if options.key?(:null)
    end

    # Changes the default value of a table column.
    def change_column_default(table_name, column_name, default)
      execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} SET DEFAULT #{quote(default)}"
    end

    def change_column_null(table_name, column_name, null, default = nil)
      unless null || default.nil?
        execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
      end
      execute("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? 'DROP' : 'SET'} NOT NULL")
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{quote_table_name(table_name)} RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
    end

    def remove_index(table_name, options) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
      return super unless type.to_s == 'integer'

      if limit.nil? || limit == 4
        'integer'
      elsif limit < 4
        'smallint'
      else
        'bigint'
      end
    end

    def tables
      @connection.tables(database_name, nil, nil, ["TABLE"])
    end

    private
    def translate_exception(exception, message)
      case exception.message
      when /duplicate key value violates unique constraint/
        ::ActiveRecord::RecordNotUnique.new(message, exception)
      when /violates foreign key constraint/
        ::ActiveRecord::InvalidForeignKey.new(message, exception)
      else
        super
      end
    end

    # Returns the list of a table's column names, data types, and default values.
    #
    # The underlying query is roughly:
    #  SELECT column.name, column.type, default.value
    #    FROM column LEFT JOIN default
    #      ON column.table_id = default.table_id
    #     AND column.num = default.column_num
    #   WHERE column.table_id = get_table_id('table_name')
    #     AND column.num > 0
    #     AND NOT column.is_dropped
    #   ORDER BY column.num
    #
    # If the table name is not prefixed with a schema, the database will
    # take the first match from the schema search path.
    #
    # Query implementation notes:
    #  - format_type includes the column size constraint, e.g. varchar(50)
    #  - ::regclass is a function that gives the id for a table name
    def column_definitions(table_name) #:nodoc:
      exec_query(<<-end_sql, 'SCHEMA')
            SELECT a.attname as column_name, format_type(a.atttypid, a.atttypmod) as column_type, d.adsrc as column_default, a.attnotnull as column_not_null
              FROM pg_attribute a LEFT JOIN pg_attrdef d
                ON a.attrelid = d.adrelid AND a.attnum = d.adnum
             WHERE a.attrelid = '#{quote_table_name(table_name)}'::regclass
               AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY a.attnum
          end_sql
    end

    def extract_pg_identifier_from_name(name)
      match_data = name[0,1] == '"' ? name.match(/\"([^\"]+)\"/) : name.match(/([^\.]+)/)

      if match_data
        rest = name[match_data[0].length..-1]
        rest = rest[1..-1] if rest[0,1] == "."
        [match_data[1], (rest.length > 0 ? rest : nil)]
      end
    end

    # from rails postgresl_adapter
    def extract_table_ref_from_insert_sql(sql)
      sql[/into\s+([^\(]*).*values\s*\(/i]
      $1.strip if $1
    end
  end
end

module ActiveRecord::ConnectionAdapters
  remove_const(:PostgreSQLAdapter) if const_defined?(:PostgreSQLAdapter)

  class PostgreSQLColumn < JdbcColumn
    include ArJdbc::PostgreSQL::Column

    def initialize(name, *args)
      if Hash === name
        super
      else
        super(nil, name, *args)
      end
    end

    def call_discovered_column_callbacks(*)
    end
  end

  class PostgreSQLAdapter < JdbcAdapter
    include ArJdbc::PostgreSQL

    def jdbc_connection_class(spec)
      ::ArJdbc::PostgreSQL.jdbc_connection_class
    end

    def jdbc_column_class
      ActiveRecord::ConnectionAdapters::PostgreSQLColumn
    end

    alias_chained_method :columns, :query_cache, :pg_columns
  end
end
