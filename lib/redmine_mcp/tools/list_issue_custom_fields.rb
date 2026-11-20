# frozen_string_literal: true

module RedmineMcp
  module Tools
    class ListIssueCustomFields < Base
      tool_name 'list_issue_custom_fields'
      title 'List issue custom fields'
      description 'List the custom fields you can set when creating an issue in a project, with their ' \
                  'required flag and allowed values. Pass the result to create_issue as custom_fields.'
      # The call only reads, so the OAuth scope it asks for is a read scope. The
      # role's add_issues permission still decides who may use it, see below.
      permission :view_issues
      input_schema(
        'type' => 'object',
        'properties' => {
          'project' => { 'type' => %w[string integer],
                         'description' => 'Project identifier or numeric id.' },
          'tracker' => { 'type' => 'string',
                         'description' => 'Tracker name. Defaults to the first tracker of the project.' }
        },
        'required' => %w[project],
        'additionalProperties' => false
      )

      # Stays hidden from roles that cannot create issues, as when the tool
      # declared add_issues itself.
      def self.available_to?(user, oauth_scopes:)
        super && role_allows?(user, oauth_scopes: oauth_scopes, permissions: %i[add_issues])
      end

      private

      # Checks the role only: add_issues is a write-tier scope, and a read tool
      # must not demand one. Whether the role may create issues is the whole
      # question here; scope narrowing is enforced for view_issues by the gate.
      def perform(arguments)
        project = fetch_project(arguments['project'])
        user.oauth_scope = nil
        begin
          authorize!(:add_issues, project)
        ensure
          user.oauth_scope = oauth_scopes
        end

        tracker = IssueCustomFields.tracker_for(project, arguments['tracker'])
        issue = IssueCustomFields.new_issue(project, tracker, user)

        { project_identifier: project.identifier, tracker: tracker.name,
          custom_fields: IssueCustomFields.describe(issue, user) }
      end
    end
  end
end
