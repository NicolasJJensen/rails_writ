class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  PAPERTRAIL_ATTRIBUTES = [
    :user,
    :ip_address,
    :user_agent
  ].freeze

  # This overrides the paper_trail helpers
  # It automatically sets the user and
  def self.has_paper_trail(**opts)
    meta = {
      user: proc { Current.user },
      ip_address: proc { Current.ip_address },
      user_agent: proc { Current.user_agent },
      **opts[:meta]
    }

    super **opts.merge(meta: meta)
  end

  scope :not_missing_any, ->(*args) do
    where(arel_table[:id].not_in(where.missing(*args).select(:id).arel))
  end

  scope :not_missing_all, ->(*args) do
    left_joins(*args).where.not(args.index_with { { id: nil } })
  end
end
