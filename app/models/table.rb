class Table < ActiveRecord::Base
  include SearchableModel

  auto_strip_attributes :name, nullify: false
  validates :name,
            length: { maximum: Constants::NAME_MAX_LENGTH }
  validates :contents,
            presence: true,
            length: { maximum: Constants::TABLE_JSON_MAX_SIZE_MB.megabytes }

  belongs_to :created_by, foreign_key: 'created_by_id', class_name: 'User'
  belongs_to :last_modified_by, foreign_key: 'last_modified_by_id', class_name: 'User'
  belongs_to :team
  has_one :step_table, inverse_of: :table
  has_one :step, through: :step_table

  has_one :result_table, inverse_of: :table
  has_one :result, through: :result_table
  has_many :report_elements, inverse_of: :table, dependent: :destroy

  after_save :update_ts_index
  #accepts_nested_attributes_for :table

  def self.search(user, include_archived, query = nil, page = 1)
    step_ids =
      Step
      .search(user, include_archived, nil, Constants::SEARCH_NO_LIMIT)
      .joins(:step_tables)
      .distinct
      .pluck('step_tables.id')

    result_ids =
      Result
      .search(user, include_archived, nil, Constants::SEARCH_NO_LIMIT)
      .joins(:result_table)
      .distinct
      .pluck('result_tables.id')

    if query
      a_query = query.strip
                     .gsub('_', '\\_')
                     .gsub('%', '\\%')
                     .split(/\s+/)
                     .map { |t| '%' + t + '%' }
    else
      a_query = query
    end

    # Trim whitespace and replace it with OR character. Make prefixed
    # wildcard search term and escape special characters.
    # For example, search term 'demo project' is transformed to
    # 'demo:*|project:*' which makes word inclusive search with postfix
    # wildcard.
    s_query = query.gsub(/[!()&|:]/, " ")
      .strip
      .split(/\s+/)
      .map {|t| t + ":*" }
      .join("|")
      .gsub('\'', '"')

    table_query =
      Table
      .distinct
      .joins("LEFT OUTER JOIN step_tables ON step_tables.table_id = tables.id")
      .joins("LEFT OUTER JOIN result_tables ON result_tables.table_id = tables.id")
      .joins("LEFT OUTER JOIN results ON result_tables.result_id = results.id")
      .where("step_tables.id IN (?) OR result_tables.id IN (?)", step_ids, result_ids)
      .where(
        '(trim_html_tags(tables.name) ILIKE ANY (array[?])'\
        'OR tables.data_vector @@ to_tsquery(?))',
        a_query,
        s_query
      )

    new_query = table_query

    # Show all results if needed
    if page == Constants::SEARCH_NO_LIMIT
      new_query
    else
      new_query
        .limit(Constants::SEARCH_LIMIT)
        .offset((page - 1) * Constants::SEARCH_LIMIT)
    end
  end

  def contents_utf_8
    contents.present? ? contents.force_encoding(Encoding::UTF_8) : nil
  end

  def update_ts_index
    if contents_changed?
      sql = "UPDATE tables " +
            "SET data_vector = " +
            "to_tsvector(substring(encode(contents::bytea, 'escape'), 9)) " +
            "WHERE id = " + Integer(id).to_s
      Table.connection.execute(sql)
    end
  end
end
