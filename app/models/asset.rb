class Asset < ActiveRecord::Base
  include SearchableModel
  include DatabaseHelper
  include Encryptor
  include WopiUtil

  require 'tempfile'
  # Lock duration set to 30 minutes
  LOCK_DURATION = 60*30

  # Paperclip validation
  has_attached_file :file,
                    styles: { large: [Constants::LARGE_PIC_FORMAT, :jpg],
                              medium: [Constants::MEDIUM_PIC_FORMAT, :jpg] },
                    convert_options: { medium: '-quality 70 -strip' }

  validates_attachment :file,
                       presence: true,
                       size: {
                         less_than: Constants::FILE_MAX_SIZE_MB.megabytes
                       }
  validates :estimated_size, presence: true
  validates :file_present, inclusion: { in: [true, false] }

  # Should be checked for any security leaks
  do_not_validate_attachment_file_type :file

  # adds image processing in background job
  process_in_background :file,
                        only_process: lambda { |a|
                                        if a.content_type ==
                                           %r{^image/#{ Regexp.union(
                                             Constants::WHITELISTED_IMAGE_TYPES
                                           ) }}
                                          [:large, :medium]
                                        else
                                          {}
                                        end
                                      },
                        processing_image_url: '/images/:style/processing.gif'

  # Asset validation
  # This could cause some problems if you create empty asset and want to
  # assign it to result
  validate :step_or_result

  belongs_to :created_by, foreign_key: 'created_by_id', class_name: 'User'
  belongs_to :last_modified_by,
             foreign_key: 'last_modified_by_id',
             class_name: 'User'
  belongs_to :team
  has_one :step_asset,
          inverse_of: :asset,
          dependent: :destroy
  has_one :step, through: :step_asset,
    dependent: :nullify

  has_one :result_asset,
    inverse_of: :asset,
    dependent: :destroy
  has_one :result, through: :result_asset,
    dependent: :nullify
  has_many :report_elements, inverse_of: :asset, dependent: :destroy
  has_one :asset_text_datum, inverse_of: :asset, dependent: :destroy

  # Specific file errors propagate to "file" error hash key,
  # so use just these errors
  after_validation :filter_paperclip_errors
  # Needed because Paperclip validatates on creation
  after_initialize :filter_paperclip_errors, if: :new_record?
  before_destroy :paperclip_delete, prepend: true

  attr_accessor :file_content, :file_info, :preview_cached

  def file_empty(name, size)
    file_ext = name.split(".").last
    self.file_file_name = name
    self.file_content_type = Rack::Mime.mime_type(".#{file_ext}")
    self.file_file_size = size
    self.file_updated_at = DateTime.now
    self.file_present = false
  end

  def self.new_empty(name, size)
    asset = self.new
    asset.file_empty name, size
    asset
  end

  def self.search(
    user,
    include_archived,
    query = nil,
    page = 1
  )
    step_ids =
      Step
      .search(user, include_archived, nil, Constants::SEARCH_NO_LIMIT)
      .joins(:step_assets)
      .distinct
      .pluck('step_assets.id')

    result_ids =
      Result
      .search(user, include_archived, nil, Constants::SEARCH_NO_LIMIT)
      .joins(:result_asset)
      .distinct
      .pluck('result_assets.id')

    if query
      a_query = query.strip
      .gsub("_","\\_")
      .gsub("%","\\%")
      .split(/\s+/)
      .map {|t|  "%" + t + "%" }
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

    ids = Asset
      .select(:id)
      .distinct
      .joins("LEFT OUTER JOIN step_assets ON step_assets.asset_id = assets.id")
      .joins("LEFT OUTER JOIN result_assets ON result_assets.asset_id = assets.id")
      .joins("LEFT JOIN asset_text_data ON assets.id = asset_text_data.asset_id")
      .where("(step_assets.id IN (?) OR result_assets.id IN (?))", step_ids, result_ids)
      .where(
        "(assets.file_file_name ILIKE ANY (array[?]) " +
        "OR asset_text_data.data_vector @@ to_tsquery(?))",
        a_query,
        s_query
      )

    # Show all results if needed
    if page != Constants::SEARCH_NO_LIMIT
      ids = ids
            .limit(Constants::SEARCH_LIMIT)
            .offset((page - 1) * Constants::SEARCH_LIMIT)
    end

    Asset
      .joins("LEFT JOIN asset_text_data ON assets.id = asset_text_data.asset_id")
      .select("assets.*")
      .select("ts_headline(data, to_tsquery('" + s_query + "'),
        'StartSel=<mark>, StopSel=</mark>') headline")
      .where("assets.id IN (?)",  ids)
  end

  def is_image?
    %r{^image/#{Regexp.union(Constants::WHITELISTED_IMAGE_TYPES)}} ===
      file.content_type
  end

  def text?
    Constants::TEXT_EXTRACT_FILE_TYPES.any? do |v|
      file_content_type.start_with? v
    end
  end

  # TODO: get the current_user
  # before_save do
  #   if current_user
  #     self.created_by ||= current_user
  #     self.last_modified_by = current_user if self.changed?
  #   end
  # end

  def is_stored_on_s3?
    file.options[:storage].to_sym == :s3
  end

  def post_process_file(team = nil)
    # Update self.empty
    self.update(file_present: true)

    # Extract asset text if it's of correct type
    if text?
      Rails.logger.info "Asset #{id}: Creating extract text job"
      # The extract_asset_text also includes
      # estimated size calculation
      delay(queue: :assets).extract_asset_text(team)
    else
      # Update asset's estimated size immediately
      update_estimated_size(team)
    end
  end

  def extract_asset_text(team = nil)
    if file.blank?
      return
    end

    begin
      file_path = file.path

      if file.is_stored_on_s3?
        fa = file.fetch
        file_path = fa.path
      end

      if (!Yomu.class_eval('@@server_pid'))
        Yomu.server(:text,nil)
        sleep(5)
      end
      y = Yomu.new file_path

      text_data = y.text

      if asset_text_datum.present?
        # Update existing text datum if it exists
        asset_text_datum.update(data: text_data)
      else
        # Create new text datum
        AssetTextDatum.create(data: text_data, asset: self)
      end

      Rails.logger.info "Asset #{id}: Asset file successfully extracted"

      # Finally, update asset's estimated size to include
      # the data vector
      update_estimated_size(team)
    rescue Exception => e
      Rails.logger.fatal "Asset #{id}: Error extracting contents from asset file #{file.path}: " + e.message
    ensure
      File.delete file_path if fa
    end
  end

  # Workaround for making Paperclip work with asset deletion (might be because
  # of how the asset models are implemented)
  def paperclip_delete
    report_elements.destroy_all
    asset_text_datum.destroy if asset_text_datum.present?
    # Nullify needed to force paperclip file deletion
    self.file = nil
    save
  end

  def destroy
    super()
    # Needed, otherwise the object isn't deleted, because of how the asset
    # models are implemented
    delete
  end

  # If team is provided, its space_taken
  # is updated as well
  def update_estimated_size(team = nil)
    if file_file_size.blank?
      return
    end

    es = file_file_size
    if asset_text_datum.present? and asset_text_datum.persisted? then
      asset_text_datum.reload
      es += get_octet_length_record(asset_text_datum, :data)
      es += get_octet_length_record(asset_text_datum, :data_vector)
    end
    es *= Constants::ASSET_ESTIMATED_SIZE_FACTOR
    update(estimated_size: es)
    Rails.logger.info "Asset #{id}: Estimated size successfully calculated"

    # Finally, update team's space
    if team.present?
      team.take_space(es)
      team.save
    end
  end

  def url(style = :original, timeout: Constants::URL_SHORT_EXPIRE_TIME)
    if file.is_stored_on_s3?
      presigned_url(style, timeout: timeout)
    else
      file.url(style)
    end
  end

  # When using S3 file upload, we can limit file accessibility with url signing
  def presigned_url(style = :original,
                    download: false,
                    timeout: Constants::URL_SHORT_EXPIRE_TIME)
    if file.is_stored_on_s3?
      if download
        download_arg = 'attachment; filename=' + URI.escape(file_file_name)
      else
        download_arg = nil
      end

      signer = Aws::S3::Presigner.new(client: S3_BUCKET.client)
      signer.presigned_url(:get_object,
        bucket: S3_BUCKET.name,
        key: file.path(style)[1..-1],
        expires_in: timeout,
        # this response header forces object download
        response_content_disposition: download_arg)
    end
  end

  def open
    if file.is_stored_on_s3?
      Kernel.open(presigned_url, "rb")
    else
      File.open(file.path, "rb")
    end
  end

  # Preserving attachments (on client-side) between failed validations
  # (only usable for small/few files!).
  # Needs to be called before save method and view needs to have
  # :file_content and :file_info hidden field.
  # If file is an image, it can be viewed on front-end
  # using @preview_cached with image_tag tag.
  def preserve(file_data)
    if file_data[:file_content].present?
      restore_cached(file_data[:file_content], file_data[:file_info])
    end
    cache
  end

  def can_perform_action(action)
    if ENV['WOPI_ENABLED'] == 'true'
      file_ext = file_file_name.split('.').last

      if file_ext == 'wopitest' &&
         (!ENV['WOPI_TEST_ENABLED'] || ENV['WOPI_TEST_ENABLED'] == 'false')
        return false
      end
      action = get_action(file_ext, action)
      return false if action.nil?
      true
    else
      false
    end
  end

  def get_action_url(user, action, with_tokens = true)
    file_ext = file_file_name.split('.').last
    action = get_action(file_ext, action)
    if !action.nil?
      action_url = action.urlsrc
      action_url = action_url.gsub(/<IsLicensedUser=BUSINESS_USER&>/,
                                   'IsLicensedUser=0&')
      action_url = action_url.gsub(/<IsLicensedUser=BUSINESS_USER>/,
                                   'IsLicensedUser=0')
      action_url = action_url.gsub(/<.*?=.*?>/, '')

      rest_url = Rails.application.routes.url_helpers.wopi_rest_endpoint_url(
        host: ENV['WOPI_ENDPOINT_URL'],
        id: id
      )
      action_url += "WOPISrc=#{rest_url}"
      if with_tokens
      	token = user.get_wopi_token
        action_url + "&access_token=#{token.token}"\
        "&access_token_ttl=#{(token.ttl * 1000)}"
      else
        action_url
      end
    else
      return nil
    end
  end

  def favicon_url(action)
    file_ext = file_file_name.split('.').last
    action = get_action(file_ext, action)
    action.wopi_app.icon if action.try(:wopi_app)
  end

  # locked?, lock_asset and refresh_lock rely on the asset
  # being locked in the database to prevent race conditions
  def locked?
    !lock.nil?
  end

  def lock_asset(lock_string)
    self.lock = lock_string
    self.lock_ttl = Time.now.to_i + LOCK_DURATION
    delay(queue: :assets, run_at: LOCK_DURATION.seconds.from_now).unlock_expired
    save!
  end

  def refresh_lock
    self.lock_ttl = Time.now.to_i + LOCK_DURATION
    delay(queue: :assets, run_at: LOCK_DURATION.seconds.from_now).unlock_expired
    save!
  end

  def unlock
    self.lock = nil
    self.lock_ttl = nil
    save!
  end

  def unlock_expired
    with_lock do
      if !lock_ttl.nil? && lock_ttl >= Time.now.to_i
        self.lock = nil
        self.lock_ttl = nil
        save!
      end
    end
  end

  def update_contents(new_file)
    new_file.class.class_eval { attr_accessor :original_filename }
    new_file.original_filename = file_file_name
    self.file = new_file
    self.version = version.nil? ? 1 : version + 1
    save
  end

  protected

  # Checks if attachments is an image (in post processing imagemagick will
  # generate styles)
  def allow_styles_on_images
    if !(file.content_type =~ %r{^(image|(x-)?application)/(x-png|pjpeg|jpeg|jpg|png|gif)$})
      return false
    end
  end

  private

  def filter_paperclip_errors
    if errors.size > 1
      temp_errors = errors[:file]
      errors.clear
      errors.set(:file, temp_errors)
    end
  end

  def file_changed?
    previous_changes.present? and
    (
      (
        previous_changes.key? "file_file_name" and
        previous_changes["file_file_name"].first !=
          previous_changes["file_file_name"].last
      ) or (
        previous_changes.key? "file_file_size" and
        previous_changes["file_file_size"].first !=
          previous_changes["file_file_size"].last
      )
    )
  end

  def step_or_result
    # We must allow both step and result to be blank because of GUI
    # (even though it's not really a "valid" asset)
    if step.present? && result.present?
      errors.add(:base, "Asset can only be result or step, not both.")
    end
  end

  def cache
    fetched_file = file.fetch
    file_content = fetched_file.read
    @file_content = encrypt(file_content)
    @file_info = %Q[{"content_type" : "#{file.content_type}", "original_filename" : "#{file.original_filename}"}]
    @file_info = encrypt(@file_info)
    if !(file.content_type =~ /^image/).nil?
      @preview_cached = "data:image/png;base64," + Base64.encode64(file_content)
    end
  end

  def restore_cached(file_content, file_info)
    decoded_data = decrypt(file_content)
    decoded_data_info = decrypt(file_info)
    decoded_data_info = JSON.parse decoded_data_info

    data = StringIO.new(decoded_data)
    data.class_eval do
      attr_accessor :content_type, :original_filename
    end
    data.content_type = decoded_data_info['content_type']
    data.original_filename = File.basename(decoded_data_info['original_filename'])

    self.file = data
  end
end
