# frozen_string_literal: true

module RedmineMcp
  module Tools
    class GetIssue < Base
      tool_name 'get_issue'
      title 'Get issue'
      description 'Fetch one issue by id, with its fields and optionally its notes, history, ' \
                  'relations, children, watchers, attachment metadata and spent hours.'
      permission :view_issues
      input_schema(
        'type' => 'object',
        'properties' => {
          'id' => { 'type' => 'integer', 'description' => 'Issue id.' },
          'include_journals' => { 'type' => 'boolean',
                                  'description' => 'Include notes and change history. Defaults to true.' },
          'include_relations' => { 'type' => 'boolean',
                                   'description' => 'Include relations to other visible issues. Defaults to false.' },
          'include_children' => { 'type' => 'boolean',
                                  'description' => 'Include visible child issues. Defaults to false.' },
          'include_watchers' => { 'type' => 'boolean',
                                  'description' => 'Include watchers. Requires view_issue_watchers. Defaults to false.' },
          'include_attachments' => { 'type' => 'boolean',
                                     'description' => 'Include a paginated page of attachment metadata (not ' \
                                                      'bytes). Defaults to false.' },
          'attachments_offset' => { 'type' => 'integer', 'minimum' => 0,
                                    'description' => 'Attachments to skip when paging the include. Defaults to 0.' },
          'attachments_limit' => { 'type' => 'integer', 'minimum' => 1,
                                   'description' => 'Maximum attachments to return, clamped by the server cap.' },
          'include_spent_hours' => { 'type' => 'boolean',
                                     'description' => 'Include spent and total spent hours. Requires ' \
                                                      'view_time_entries. Defaults to false.' }
        },
        'required' => %w[id],
        'additionalProperties' => false
      )

      # The privileged includes add their own permission so the HTTP gate can
      # challenge for the whole operation before the body runs; the execution
      # backstop re-checks them too.
      def self.required_permissions(arguments = {}, user: User.current)
        permissions = super
        permissions += %i[view_issue_watchers] if arguments['include_watchers'] == true
        permissions += %i[view_time_entries] if arguments['include_spent_hours'] == true
        permissions
      end

      private

      def perform(arguments)
        issue = Issue.visible(user).find_by(id: arguments['id'].to_i)
        raise ToolError, "No visible issue with id #{arguments['id'].inspect}" if issue.nil?

        authorize!(:view_issues, issue.project)

        payload = {
          id: issue.id,
          subject: issue.subject,
          description: issue.description,
          project: issue.project&.name,
          project_identifier: issue.project&.identifier,
          tracker: issue.tracker&.name,
          status: status_ref(issue.status),
          priority: issue.priority&.name,
          author: identity(issue.author),
          assigned_to: identity(issue.assigned_to),
          category: issue.category&.name,
          fixed_version: issue.fixed_version&.name,
          parent_id: issue.parent_id,
          start_date: issue.start_date&.iso8601,
          due_date: issue.due_date&.iso8601,
          done_ratio: issue.done_ratio,
          estimated_hours: issue.estimated_hours,
          is_private: issue.is_private?,
          created_on: iso(issue.created_on),
          updated_on: iso(issue.updated_on),
          closed_on: iso(issue.closed_on),
          # Unconditional, so a caller knows whether to page the metadata include.
          attachments_count: issue.attachments.size,
          custom_fields: visible_custom_fields(issue)
        }

        payload[:journals]    = journals_for(issue) if arguments.fetch('include_journals', true)
        payload[:relations]   = relations_for(issue) if arguments['include_relations'] == true
        payload[:children]    = children_for(issue) if arguments['include_children'] == true
        payload[:attachments] = attachments_page(issue, arguments) if arguments['include_attachments'] == true

        if arguments['include_watchers'] == true
          authorize!(:view_issue_watchers, issue.project)
          payload[:watchers] = issue.watcher_users.map { |u| identity(u) }
        end

        if arguments['include_spent_hours'] == true
          authorize!(:view_time_entries, issue.project)
          payload[:spent_hours] = issue.spent_hours
          payload[:total_spent_hours] = issue.total_spent_hours
        end

        payload
      end

      # Issue#visible_custom_field_values applies per-field role visibility.
      # Reading custom_field_values directly would leak fields core hides.
      def visible_custom_fields(issue)
        issue.visible_custom_field_values.map do |value|
          { id: value.custom_field_id, name: value.custom_field.name, value: value.value }
        end
      end

      # Journal#notes can be private (private_notes), and core gates that on
      # :view_private_notes. Journal.visible applies exactly that rule.
      def journals_for(issue)
        issue.journals.visible(user).includes(:user).order(:created_on).map do |journal|
          {
            id: journal.id,
            user: identity(journal.user),
            notes: journal.notes.presence,
            private_notes: journal.private_notes?,
            created_on: iso(journal.created_on),
            details: journal.visible_details(user).map { |detail| detail_json(detail) }
          }
        end
      end

      # The record an attribute change points at by id, resolved so a model can
      # reconstruct the history without a second lookup per id. Looked up on
      # use: the models are not loadable while the plugin boots.
      def referenced_class(attribute)
        case attribute
        when 'status_id' then IssueStatus
        when 'priority_id' then IssuePriority
        when 'tracker_id' then Tracker
        when 'category_id' then IssueCategory
        when 'fixed_version_id' then Version
        end
      end

      # Resolves record references to {id, name} and an assignee to a typed
      # identity; a custom field change gains the field's name and, where the
      # stored value is not what a person reads, the label. Everything else
      # keeps its raw before/after string.
      def detail_json(detail)
        base = { property: detail.property, name: detail.prop_key }
        klass = referenced_class(detail.prop_key) if detail.property == 'attr'
        if klass
          base.merge(old_value: record_ref(klass, detail.old_value), new_value: record_ref(klass, detail.value))
        elsif detail.property == 'attr' && detail.prop_key == 'assigned_to_id'
          base.merge(old_value: principal_by_id(detail.old_value), new_value: principal_by_id(detail.value))
        elsif detail.property == 'cf'
          custom_field_detail(base, detail)
        else
          base.merge(old_value: detail.old_value, new_value: detail.value)
        end
      end

      def record_ref(klass, raw)
        return nil if raw.blank?

        record = klass.find_by(id: raw.to_i)
        record ? { id: record.id, name: record.name } : raw
      end

      # Labels come from core's own field formats, the way the issue history
      # page renders them. A deleted field keeps the raw detail.
      def custom_field_detail(base, detail)
        field = detail.custom_field
        detail_hash = base.merge(old_value: detail.old_value, new_value: detail.value)
        return detail_hash if field.nil?

        detail_hash[:field] = field.name
        { old_label: detail.old_value, new_label: detail.value }.each do |key, raw|
          label = custom_field_label(field, raw)
          detail_hash[key] = label if label && label != raw
        end
        detail_hash
      end

      def custom_field_label(field, raw)
        return nil if raw.blank?

        field.format.formatted_value(nil, field, raw, nil, false).to_s
      end

      def principal_by_id(raw)
        return nil if raw.blank?

        identity(Principal.find_by(id: raw.to_i))
      end

      def relations_for(issue)
        issue.relations.filter_map do |relation|
          other = relation.other_issue(issue)
          next if other.nil? || !other.visible?(user)

          { id: relation.id, type: relation.relation_type_for(issue),
            issue_id: other.id, issue_subject: other.subject }
        end
      end

      def children_for(issue)
        issue.children.select { |child| child.visible?(user) }.map do |child|
          { id: child.id, subject: child.subject, tracker: child.tracker&.name, status: child.status&.name }
        end
      end

      # One pagination envelope of attachment metadata, so an issue with many
      # attachments cannot dump an unbounded list into the model's context. The
      # attachments-specific offset/limit keep this page independent of any other
      # include, and the limit is clamped by the administrator's result cap.
      def attachments_page(issue, arguments)
        visible = issue.attachments.select { |attachment| attachment.visible?(user) }
        offset  = [arguments['attachments_offset'].presence&.to_i || 0, 0].max
        limit   = attachments_limit(arguments)
        rows    = (visible.slice(offset, limit) || []).map { |attachment| attachment_metadata(issue, attachment) }
        paged(total: visible.size, offset: offset, key: :items, rows: rows)
      end

      def attachments_limit(arguments)
        requested = arguments['attachments_limit'].presence&.to_i
        return Settings.max_results if requested.nil?

        [[requested, 1].max, Settings.max_results].min
      end

      # Metadata only; bytes are read through the attachment Resource, so each
      # item carries its stable resource URI rather than content. The
      # human_download_url is a credential-free manual fallback for a user already
      # authenticated to Redmine -- not a client-fetchable MCP resource -- and is
      # what the too-large resources/read error points back to.
      def attachment_metadata(issue, attachment)
        {
          id: attachment.id,
          filename: attachment.filename,
          filesize: attachment.filesize,
          content_type: attachment.content_type.presence,
          description: attachment.description.presence,
          author: identity(attachment.author),
          created_on: iso(attachment.created_on),
          resource_uri: "redmine://issues/#{issue.id}/attachments/#{attachment.id}",
          human_download_url: RedmineMcp::Resources.download_url(attachment)
        }
      end

      # A resource_link block per returned attachment, so a client with a
      # resource-selection UI can pull the bytes through resources/read without
      # the model first restating the URI. Built from the metadata already in the
      # payload's attachment page, so it stays in step with the include and is
      # empty whenever that include was not requested.
      def content_blocks(payload)
        page = payload[:attachments]
        items = page.is_a?(Hash) ? Array(page[:items]) : []
        items.map do |item|
          {
            type: 'resource_link',
            uri: item[:resource_uri],
            name: item[:filename],
            description: item[:description],
            mimeType: item[:content_type],
            size: item[:filesize]
          }.compact
        end
      end
    end
  end
end
