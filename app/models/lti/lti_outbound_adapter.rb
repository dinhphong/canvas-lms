# frozen_string_literal: true

#
# Copyright (C) 2014 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

module Lti
  class LtiOutboundAdapter
    cattr_writer :consumer_instance_class

    def self.consumer_instance_class
      @@consumer_instance_class || LtiOutbound::LTIConsumerInstance
    end

    def initialize(tool, user, context)
      @tool = tool
      @user = user
      @context = context

      if @context.respond_to? :root_account
        @root_account = @context.root_account
      elsif @tool.context.respond_to? :root_account
        @root_account = @tool.context.root_account
      else
        raise("Root account required for generating LTI content")
      end
    end

    # @argument opts
    #   resource_type:
    #   selected_html: selected text to be sent to the tool provider as text
    #   launch_url: a specific launch url for this launch
    #   link_code: the resource_link_id for this launch
    #   overrides
    def prepare_tool_launch(return_url, variable_expander, opts = {})
      resource_type = opts[:resource_type]
      selected_html = opts[:selected_html]
      launch_url = opts[:launch_url] || default_launch_url(resource_type)
      link_code = opts[:link_code] || default_link_code
      @overrides = opts[:overrides] || {}
      link_params = opts[:link_params] || {}
      include_module_context = opts[:include_module_context] || false

      if opts[:parent_frame_context]
        uri = URI.parse(return_url)
        new_query_ar = URI.decode_www_form(uri.query || "") << ["parent_frame_context", opts[:parent_frame_context]]
        uri.query = URI.encode_www_form(new_query_ar)
        return_url = uri.to_s
      end

      lti_context = Lti::LtiContextCreator.new(@context, @tool).convert
      lti_user = Lti::LtiUserCreator.new(@user, @root_account, @tool, @context).convert if @user
      lti_tool = Lti::LtiToolCreator.new(@tool).convert
      lti_account = Lti::LtiAccountCreator.new(@context, @tool).convert

      @tool_launch = LtiOutbound::ToolLaunch.new(
        {
          url: launch_url,
          link_code: link_code,
          return_url: return_url,
          resource_type: resource_type,
          selected_html: selected_html,
          outgoing_email_address: HostUrl.outgoing_email_address,
          context: lti_context,
          user: lti_user,
          tool: lti_tool,
          account: lti_account,
          variable_expander: variable_expander,
          link_params: link_params,
          include_module_context: include_module_context
        }
      )
      self
    end

    def generate_post_payload(assignment: nil, student_id: nil)
      raise("Called generate_post_payload before calling prepare_tool_launch") unless @tool_launch

      hash = @tool_launch.generate(@overrides)
      hash[:ext_lti_assignment_id] = assignment&.lti_context_id if assignment&.lti_context_id.present?
      hash[:ext_lti_student_id] = student_id if student_id
      begin
        Lti::Security.signed_post_params(
          hash,
          @tool_launch.url,
          @tool.consumer_key,
          @tool.shared_secret,
          disable_post_only?
        )
      rescue URI::InvalidURIError
        raise ::Lti::Errors::InvalidLaunchUrlError, "Invalid launch url: #{@tool_launch.url}"
      end
    end

    def generate_post_payload_for_assignment(assignment, outcome_service_url, legacy_outcome_service_url, lti_turnitin_outcomes_placement_url)
      raise("Called generate_post_payload_for_assignment before calling prepare_tool_launch") unless @tool_launch

      lti_assignment = Lti::LtiAssignmentCreator.new(assignment, encode_source_id(assignment)).convert
      @tool_launch.for_assignment!(lti_assignment, outcome_service_url, legacy_outcome_service_url, lti_turnitin_outcomes_placement_url)
      generate_post_payload(assignment: assignment)
    end

    def generate_post_payload_for_homework_submission(assignment)
      raise("Called generate_post_payload_for_homework_submission before calling prepare_tool_launch") unless @tool_launch

      lti_assignment = Lti::LtiAssignmentCreator.new(assignment).convert
      @tool_launch.for_homework_submission!(lti_assignment)
      generate_post_payload
    end

    def launch_url(post_only: false)
      raise("Called launch_url before calling prepare_tool_launch") unless @tool_launch

      (post_only && !disable_post_only?) ? @tool_launch.url.split("?").first : @tool_launch.url
    end

    # this is the lis_result_sourcedid field in the launch, and the
    # sourcedGUID/sourcedId in BLTI basic outcome requests.
    # it's a secure signature of the (tool, course, assignment, user). Combined with
    # the pre-determined shared secret that the tool signs requests with, this
    # ensures that only this launch of the tool can modify the score.
    def encode_source_id(assignment)
      @tool.shard.activate do
        if @root_account.feature_enabled?(:encrypted_sourcedids)
          BasicLTI::Sourcedid.new(@tool, @context, assignment, @user).to_s
        else
          payload = [@tool.id, @context.id, assignment.id, @user.id].join("-")
          "#{payload}-#{Canvas::Security.hmac_sha1(payload)}"
        end
      end
    end

    private

    def default_launch_url(resource_type = nil)
      resource_type ? @tool.extension_setting(resource_type, :url) : @tool.url
    end

    def default_link_code
      @tool.opaque_identifier_for(@context)
    end

    def disable_post_only?
      @root_account.feature_enabled?(:disable_lti_post_only) || @tool.extension_setting(:oauth_compliant)
    end
  end
end
