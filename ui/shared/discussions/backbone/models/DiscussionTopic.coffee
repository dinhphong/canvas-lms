#
# Copyright (C) 2012 - present Instructure, Inc.
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

import {useScope as useI18nScope} from '@canvas/i18n'
import Backbone from '@canvas/backbone'
import $ from 'jquery'
import _ from 'underscore'
import { showFlashError } from '@canvas/alerts/react/FlashAlert'
import ParticipantCollection from '../collections/ParticipantCollection'
import DiscussionEntriesCollection from '../collections/DiscussionEntriesCollection'
import Assignment from '@canvas/assignments/backbone/models/Assignment'
import DateGroup from '@canvas/date-group/backbone/models/DateGroup'
import axios from '@canvas/axios'

I18n = useI18nScope('discussion_topics')

stripTags = (str) ->
  div = document.createElement('div')
  div.innerHTML = str
  div.textContent or div.innerText or ''

export default class DiscussionTopic extends Backbone.Model
  resourceName: 'discussion_topics'

  defaults:
    discussion_type: 'side_comment'
    podcast_enabled: false
    podcast_has_student_posts: false
    require_initial_post: false
    is_announcement: false
    subscribed: false
    user_can_see_posts: true
    subscription_hold: null
    publishable: true
    unpublishable: true

  dateAttributes: [
    'last_reply_at'
    'posted_at'
    'delayed_post_at'
  ]

  initialize: ->
    @participants = new ParticipantCollection
    @entries = new DiscussionEntriesCollection
    @entries.url = => "#{@baseUrlWithoutQuerystring()}/entries"
    @entries.participants = @participants

  parse: (json) ->
    json.set_assignment = json.assignment?
    assign_attributes = json.assignment || {}
    assign_attributes.assignment_overrides or= []
    assign_attributes.turnitin_settings or= {}
    json.assignment = @createAssignment(assign_attributes)
    json.publishable = json.can_publish
    json.unpublishable = !json.published or json.can_unpublish

    json

  baseUrlWithoutQuerystring: ->
    baseUrl = _.result this, 'url'
    baseUrl.split('?')[0]

  createAssignment: (attributes) ->
    assign = new Assignment(attributes)
    assign.alreadyScoped = true
    assign

  # always include assignment in view presentation
  present: =>
    Backbone.Model::toJSON.call(this)

  publish: ->
    @updateOneAttribute('published', true)

  unpublish: ->
    @updateOneAttribute('published', false)

  disabledMessage: -> I18n.t 'cannot_unpublish_with_replies', "Can't unpublish if there are student replies"

  topicSubscribe: ->
    @set 'subscribed', true
    $.ajaxJSON "#{@baseUrlWithoutQuerystring()}/subscribed", 'PUT'

  topicUnsubscribe: ->
    @set 'subscribed', false
    $.ajaxJSON "#{@baseUrlWithoutQuerystring()}/subscribed", 'DELETE'

  toJSON: ->
    json = super
    delete json.message if (ENV.MASTER_COURSE_DATA?.is_master_course_child_content && ENV.MASTER_COURSE_DATA?.master_course_restrictions?.content)
    delete json.assignment unless json.set_assignment
    _.extend json,
      summary: @summary()
      unread_count_tooltip: @unreadTooltip()
      reply_count_tooltip: @replyTooltip()
      assignment: json.assignment?.toJSON()
      defaultDates: @defaultDates().toJSON()
      isRootTopic: @isRootTopic()
    delete json.assignment.rubric if json.assignment
    json

  duplicate: (context_type, context_id, callback) =>
    axios.post("/api/v1/#{context_type}s/#{context_id}/discussion_topics/#{@id}/duplicate", {})
      .then(callback)
      .catch(showFlashError(I18n.t("Could not duplicate discussion")))

  toView: ->
    _.extend @toJSON(),
      name: @get('title')

  unreadTooltip: ->
    I18n.t 'unread_count_tooltip', {
      zero:  'No unread replies.'
      one:   '1 unread reply.'
      other: '%{count} unread replies.'
    }, count: @get('unread_count')

  replyTooltip: ->
    I18n.t 'reply_count_tooltip', {
      zero:  'No replies.'
      one:   '1 reply.'
      other: '%{count} replies.'
    }, count: @get('discussion_subentry_count')

  ##
  # this is for getting the topic 'full view' from the api
  # see: https://<canvas>/doc/api/discussion_topics.html#method.discussion_topics_api.view
  fetchEntries: ->
    $.get "#{@baseUrlWithoutQuerystring()}/view", ({unread_entries, forced_entries, participants, view: entries}) =>
      @unreadEntries = unread_entries
      @forcedEntries = forced_entries
      @participants.reset participants

      # TODO: handle nested replies and 'new_entries' here
      @entries.reset(entries)

  summary: ->
    stripTags @get('message')

  # TODO: this would belong in Backbone.model, but I dont know of others are going to need it much
  # or want to commit to this api so I am just putting it here for now
  updateOneAttribute: (key, value, options = {}) ->
    data = {}
    data[key] = value
    @updatePartial(data, options)

  updatePartial: (data, options = {}) ->
    @set(data) unless options.wait
    options = _.defaults options,
      data: JSON.stringify(data)
      contentType: 'application/json'
    @save {}, options

  positionAfter: (otherId) ->
    @updateOneAttribute 'position_after', otherId, wait: true
    collection = @collection
    otherIndex = collection.indexOf collection.get(otherId)
    collection.remove this, silent: true
    collection.models.splice (otherIndex), 0, this
    collection.reset collection.models

  defaultDates: ->
    group = new DateGroup
      due_at:    @dueAt()
      unlock_at: @unlockAt()
      lock_at:   @lockAt()
    return group

  dueAt: ->
    @get('assignment')?.get('due_at')

  unlockAt: ->
    if unlock_at = @get('assignment')?.get('unlock_at')
      return unlock_at
    @get('delayed_post_at')

  lockAt:  ->
    if lock_at = @get('assignment')?.get('lock_at')
      return lock_at
    @get('lock_at')

  focusAfterMoving: ->
    $el = $(".discussion[data-id='#{@get('id')}']")
    $prev = $el.prev(".discussion")
    if $prev.length
      $(".title", $prev)
    else
      $el.closest(".discussion-list")

  updateBucket: (data) ->
    $toFocus = @focusAfterMoving()
    _.defaults data,
      pinned: @get('pinned')
      locked: @get('locked')
    @set('position', null)
    @updatePartial(data)
    # assign focus only if it was lost; a discussion in multiple categories might not have actually moved
    if !document.activeElement? || document.activeElement.nodeName == "BODY"
      $toFocus = $('.ig-header-title', $toFocus) if $toFocus.hasClass('discussion-list')
      $toFocus.focus()

  isRootTopic: () ->
    !@get('root_topic_id') && @get('group_category_id')

  groupCategoryId: (id) =>
    return @get( 'group_category_id' ) unless arguments.length > 0
    @set 'group_category_id', id

  canGroup: -> @get('can_group')
