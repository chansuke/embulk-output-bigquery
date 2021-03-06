require 'time'
require 'tzinfo'
require 'json'
require_relative 'helper'

module Embulk
  module Output
    class Bigquery < OutputPlugin
      class ValueConverterFactory
        class NotSupportedType < StandardError; end
        class TypeCastError < StandardError; end

        # ref. https://cloud.google.com/bigquery/preparing-data-for-bigquery

        DEFAULT_TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S.%6N" # BigQuery timestamp format
        DEFAULT_TIMEZONE         = "UTC"

        # @param [Hash] task
        # @option task [String] default_timestamp_format
        # @option task [String] default_timezone
        # @option task [Hash]   column_options user defined column types
        # @param [Schema] schema embulk defined column types
        # @return [Array] an arary whose key is column_index, and value is its converter (Proc)
        def self.create_converters(task, schema)
          column_options_map       = Helper.column_options_map(task['column_options'])
          default_timestamp_format = task['default_timestamp_format']
          default_timezone         = task['default_timezone']
          schema.map do |column|
            column_name   = column[:name]
            embulk_type   = column[:type]
            column_option = column_options_map[column_name] || {}
            self.new(
              embulk_type, column_option['type'],
              timestamp_format: column_option['timestamp_format'],
              timezone: column_option['timezone'],
              strict: column_option['strict'],
              default_timestamp_format: default_timestamp_format,
              default_timezone: default_timezone,
            ).create_converter
          end
        end

        attr_reader :embulk_type, :type, :timestamp_format, :timezone, :zone_offset, :strict

        def initialize(
          embulk_type, type = nil,
          timestamp_format: nil, timezone: nil, strict: nil,
          default_timestamp_format: DEFAULT_TIMESTAMP_FORMAT,
          default_timezone: DEFAULT_TIMEZONE
        )
          @embulk_type      = embulk_type
          @type             = (type || Helper.bq_type_from_embulk_type(embulk_type)).upcase
          @timestamp_format = timestamp_format
          @default_timestamp_format = default_timestamp_format
          @timezone         = timezone || default_timezone
          @zone_offset      = get_zone_offset(@timezone) if @timezone
          @strict           = strict.nil? ? true : strict
        end

        def create_converter
          case embulk_type
          when :boolean   then boolean_converter
          when :long      then long_converter
          when :double    then double_converter
          when :string    then string_converter
          when :timestamp then timestamp_converter
          when :json      then json_converter
          else raise NotSupportedType, "embulk type #{embulk_type} is not supported"
          end
        end

        def with_typecast_error(val)
          begin
            yield(val)
          rescue => e
            raise_typecast_error(val)
          end
        end

        def raise_typecast_error(val)
          message = "cannot cast #{@embulk_type} `#{val}` to #{@type}"
          if @strict
            raise TypeCastError, message
          else
            Embulk.logger.trace { message }
            return nil
          end
        end

        def boolean_converter
          case type
          when 'BOOLEAN'
            Proc.new {|val|
              val
            }
          when 'STRING'
            Proc.new {|val|
              next nil if val.nil?
              val.to_s
            }
          else
            raise NotSupportedType, "cannot take column type #{type} for boolean column"
          end
        end

        def long_converter
          case type
          when 'BOOLEAN'
            Proc.new {|val|
              next nil if val.nil?
              next true if val == 1
              next false if val == 0
              raise_typecast_error(val)
            }
          when 'INTEGER'
            Proc.new {|val|
              val
            }
          when 'FLOAT'
            Proc.new {|val|
              next nil if val.nil?
              val.to_f
            }
          when 'STRING'
            Proc.new {|val|
              next nil if val.nil?
              val.to_s
            }
          when 'TIMESTAMP'
            Proc.new {|val|
              next nil if val.nil?
              val # BigQuery supports UNIX timestamp
            }
          else
            raise NotSupportedType, "cannot take column type #{type} for long column"
          end
        end

        def double_converter
          case type
          when 'INTEGER'
            Proc.new {|val|
              next nil if val.nil?
              val.to_i
            }
          when 'FLOAT'
            Proc.new {|val|
              val
            }
          when 'STRING'
            Proc.new {|val|
              next nil if val.nil?
              val.to_s
            }
          when 'TIMESTAMP'
            Proc.new {|val|
              next nil if val.nil?
              val # BigQuery supports UNIX timestamp
            }
          else
            raise NotSupportedType, "cannot take column type #{type} for double column"
          end
        end

        def string_converter
          case type
          when 'BOOLEAN'
            Proc.new {|val|
              next nil if val.nil?
              next true if val == 'true'.freeze
              next false if val == 'false'.freeze
              raise_typecast_error(val)
            }
          when 'INTEGER'
            Proc.new {|val|
              next nil if val.nil?
              with_typecast_error(val) do |val|
                Integer(val)
              end
            }
          when 'FLOAT'
            Proc.new {|val|
              next nil if val.nil?
              with_typecast_error(val) do |val|
                Float(val)
              end
            }
          when 'STRING'
            Proc.new {|val|
              val
            }
          when 'TIMESTAMP'
            if @timestamp_format
              Proc.new {|val|
                next nil if val.nil?
                with_typecast_error(val) do |val|
                  strptime_with_zone(val, @timestamp_format, zone_offset).to_f
                end
              }
            else
              Proc.new {|val|
                next nil if val.nil?
                val # Users must care of BQ timestamp format
              }
            end
          when 'RECORD'
            Proc.new {|val|
              next nil if val.nil?
              with_typecast_error(val) do |val|
                JSON.parse(val)
              end
            }
          else
            raise NotSupportedType, "cannot take column type #{type} for string column"
          end
        end

        def timestamp_converter
          case type
          when 'INTEGER'
            Proc.new {|val|
              next nil if val.nil?
              val.to_i
            }
          when 'FLOAT'
            Proc.new {|val|
              next nil if val.nil?
              val.to_f
            }
          when 'STRING'
            _timestamp_format = @timestamp_format || @default_timestamp_format
            Proc.new {|val|
              next nil if val.nil?
              with_typecast_error(val) do |val|
                val.localtime(zone_offset).strftime(_timestamp_format)
              end
            }
          when 'TIMESTAMP'
            Proc.new {|val|
              next nil if val.nil?
              val.to_f # BigQuery supports UNIX timestamp
            }
          else
            raise NotSupportedType, "cannot take column type #{type} for timestamp column"
          end
        end

        # ToDo: recursive conversion
        def json_converter
          case type
          when 'STRING'
            Proc.new {|val|
              next nil if val.nil?
              val.to_json
            }
          when 'RECORD'
            Proc.new {|val|
              val
            }
          else
            raise NotSupportedType, "cannot take column type #{type} for json column"
          end
        end

        private
        
        # [+-]HH:MM, [+-]HHMM, [+-]HH
        NUMERIC_PATTERN = %r{\A[+-]\d\d(:?\d\d)?\z}

        # Region/Zone, Region/Zone/Zone
        NAME_PATTERN = %r{\A[^/]+/[^/]+(/[^/]+)?\z}

        def strptime_with_zone(date, timestamp_format, zone_offset)
          time = Time.strptime(date, timestamp_format)
          utc_offset = time.utc_offset
          time.localtime(zone_offset) + utc_offset - zone_offset
        end

        def get_zone_offset(timezone)
          if NUMERIC_PATTERN === timezone
            Time.zone_offset(timezone)
          elsif NAME_PATTERN === timezone || 'UTC' == timezone
            tz = TZInfo::Timezone.get(timezone)
            tz.period_for_utc(Time.now).utc_total_offset
          else
            raise ArgumentError, "timezone format is invalid: #{timezone}"
          end
        end
      end
    end
  end
end
