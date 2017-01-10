class AtWhoController < ApplicationController
  before_action :load_vars
  before_action :check_users_permissions, only: :users

  def users
    # Search users
    res = @organization
          .search_users(@query)
          .select(:id, :full_name, :email)
          .limit(Constants::ATWHO_SEARCH_LIMIT)
          .as_json

    # Add avatars, Base62, convert to JSON
    res.each do |user_obj|
      user_obj['full_name'] =
        user_obj['full_name']
        .truncate(Constants::NAME_TRUNCATION_LENGTH_DROPDOWN)
      user_obj['id'] = user_obj['id'].base62_encode
      user_obj['img_url'] = avatar_path(user_obj['id'], :icon_small)
    end

    respond_to do |format|
      format.json do
        render json: {
          users: res,
          status: :ok
        }
      end
    end
  end

  private

  def load_vars
    @organization = Organization.find_by_id(params[:id])
    @query = params[:query]
    render_404 unless @organization
  end

  def check_users_permissions
    render_403 unless can_view_organization_users(@organization)
  end
end