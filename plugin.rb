# frozen_string_literal: true

# name: optimized-privilege
# about: 
# version: 0.1
# authors: chenyxuan
# url: https://github.com/chenyxuan

register_asset 'stylesheets/common/optimized-privilege.scss'
register_asset 'stylesheets/desktop/optimized-privilege.scss', :desktop
register_asset 'stylesheets/mobile/optimized-privilege.scss', :mobile

enabled_site_setting :optimized_privilege_enabled

PLUGIN_NAME ||= 'OptimizedPrivilege'

load File.expand_path('lib/optimized-privilege/engine.rb', __dir__)

after_initialize do
  # https://github.com/discourse/discourse/blob/master/lib/plugin/instance.rb

  class ::Reviewable
    module OverridingViewableBy
      def viewable_by(user, order: nil, preload: true)
        return none unless user.present?

        result = self.order(order || 'reviewables.score desc, reviewables.created_at desc')

        if preload
          result = result.includes(
            { created_by: :user_stat },
            :topic,
            :target,
            :target_created_by,
            :reviewable_histories
          ).includes(reviewable_scores: { user: :user_stat, meta_topic: :posts })
        end
        
        privileged_users = SiteSetting.optimized_privilege_users.split('|')
        if privileged_users.include?(user.id.to_s)
          result = result.where("reviewables.created_by_id = ?", user.id)
        end

        return result if user.admin?

        group_ids = SiteSetting.enable_category_group_moderation? ? user.group_users.pluck(:group_id) : []

        result.where(
          '(reviewables.reviewable_by_moderator AND :staff) OR (reviewables.reviewable_by_group_id IN (:group_ids))',
          staff: user.staff?,
          group_ids: group_ids
        ).where("reviewables.category_id IS NULL OR reviewables.category_id IN (?)", Guardian.new(user).allowed_category_ids)
      end
    end
    
    singleton_class.prepend OverridingViewableBy
    
  end
  
  

  class ::Jobs::NotifyReviewable
    module OverridingExecute
      def execute(args)
        return unless reviewable = Reviewable.find_by(id: args[:reviewable_id])

        @contacted = Set.new

        counts = Hash.new(0)
        
        candidates = Set.new
        candidates += User.real.admins.pluck(:username)
        candidates += User.real.moderators.pluck(:username)

        ccounts = Hash.new(0)

        Reviewable.default_visible.pending.each do |r|
          candidates.each do |cname|
            user = User.find_by_username(cname)
            ccounts[cname] += 1 if r.viewable_by(user)
          end
          counts[r.reviewable_by_group_id] += 1 if r.reviewable_by_group_id
        end

        # admin and moderators
        candidates.each do |cname|
            user = User.find_by_username(cname)
            user_id = User.find_by_username(cname)&.id
            notify(ccount[cname], [user_id]) if reviewable.viewable_by(user)
        end

        # category moderators
        if SiteSetting.enable_category_group_moderation? && (group = reviewable.reviewable_by_group)
          group.users.includes(:group_users).where("users.id NOT IN (?)", @contacted).find_each do |user|
            count = user.group_users.map { |gu| counts[gu.group_id] }.sum
            notify(count, [user.id])
          end
        end
      end
    end
    
    prepend OverridingExecute
    
  end
  
  
  class ::Guardian
    module OverridingGuardian

      def can_banner_topic?(topic)
        if topic && authenticated? && !topic.private_message? && is_staff?
          privileged_users = SiteSetting.optimized_privilege_users.split('|')
          return false if privileged_users.include?(@user.id.to_s)
          return true
        end
        return false
      end

      def can_see_whispers?(_topic)
        privileged_users = SiteSetting.optimized_privilege_users.split('|')
        return false if privileged_users.include?(@user.id.to_s)
        is_staff?
      end

      def can_see_flagged_posts?
        privileged_users = SiteSetting.optimized_privilege_users.split('|')
        return false if privileged_users.include?(@user.id.to_s)
        is_staff?
      end
    
      def can_see_deleted_posts?(category = nil)
        privileged_users = SiteSetting.optimized_privilege_users.split('|')
        return false if privileged_users.include?(@user.id.to_s)
        is_staff? || is_category_group_moderator?(category)
      end

    # Deleting Methods
      def can_delete_post?(post)
        return false if !can_see_post?(post)

        # Can't delete the first post
        return false if post.is_first_post?

        # Can't delete posts in archived topics unless you are staff
        can_moderate = can_moderate_topic?(post.topic)
        return false if !can_moderate && post.topic&.archived?

        # You can delete your own posts
        return !post.user_deleted? if is_my_own?(post)

        # Admin can delete any posts
        return true if is_admin?
        
        # You can't delete optimized_privilege_trust_level user's posts
        
        return false if post.user.has_trust_level?(TrustLevel[SiteSetting.optimized_privilege_trust_level.to_i])

        can_moderate
      end

      def can_delete_topic?(topic)
        !topic.trashed? &&
        (is_admin? || (is_staff? && !topic.user.has_trust_level?(TrustLevel[SiteSetting.optimized_privilege_trust_level.to_i])) || (is_my_own?(topic)) || is_category_group_moderator?(topic.category)) &&
        !topic.is_category_topic? &&
        !Discourse.static_doc_topic_ids.include?(topic.id)
      end
      
      def can_edit_staff_notes?(topic)
        return false if anonymous? || topic.nil?
        privileged_users = SiteSetting.optimized_privilege_users.split('|')
        return false if privileged_users.include?(@user.id.to_s)
        return true if is_staff?
        return true if @user.has_trust_level?(TrustLevel[4])

        is_category_group_moderator?(topic.category)
      end

      def can_check_emails?(user)
        false
      end

      def can_check_sso_email?(user)
        false
      end

      def can_silence_user?(user)
        privileged_groups = SiteSetting.optimized_privilege_groups.split('|')

        sql = <<~SQL
                SELECT group_users.user_id
                FROM groups
                JOIN group_users ON group_users.group_id = groups.id
                AND groups.name IN (:privileged_groups)
              SQL
        privileged_users = DB.query_single(sql, privileged_groups: privileged_groups)
        
        if user && is_staff? 
          # let frontend show 500 interval error
          raise if privileged_users.include?(user.id)
          not(user.staff?)
        else
          false
        end
      end
    end
    
    prepend OverridingGuardian

  end
  
  class ::PostSerializer
    module OverridingFlagCount
      def reviewable_id
        0
      end
    end
    
    prepend OverridingFlagCount
  end
  
  class ::Topic
    module OverridingPrivilege

      def update_status(status, enabled, user, opts = {})
        privileged_users = SiteSetting.optimized_privilege_users.split('|')
        raise if privileged_users.include?(user.id.to_s)
        super(status, enabled, user, opts)
      end

    end

    prepend OverridingPrivilege
  end

end
