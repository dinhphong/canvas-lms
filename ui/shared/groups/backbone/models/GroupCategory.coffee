#
# Copyright (C) 2013 - present Instructure, Inc.
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

import $ from 'jquery'
import _ from 'underscore'
import Backbone from '@canvas/backbone'
import GroupCollection from '../collections/GroupCollection'
import UnassignedGroupUserCollection from '../collections/UnassignedGroupUserCollection'
import progressable from '@canvas/progress/backbone/models/progressable'
import DefaultUrlMixin from '@canvas/backbone/DefaultUrlMixin'

export default class GroupCategory extends Backbone.Model

  resourceName: "group_categories"
  @mixin progressable

  initialize: ->
    super
    if groups = @get('groups')
      @groups groups
    @on 'change:group_limit', @updateGroups

  updateGroups: ->
    if @_groups
      @_groups.fetch()

  groups: (models = null) ->
    @_groups = new GroupCollection models,
      category: this
      loadAll: true
      markInactiveStudents: @collection?.options?.markInactiveStudents
    if @get('groups_count') is 0 or models?.length
      @_groups.loadedAll = true
    else
      @_groups.fetch()
    @_groups.on 'fetched:last', => @set('groups_count', @_groups.length)
    @_groups.on 'remove', @groupRemoved
    @groups = -> @_groups
    @_groups

  groupRemoved: (group) =>
    # update/reset the unassigned users collection (if it's around)
    return unless @_unassignedUsers or group.usersCount()

    users = group.users()
    if users.loadedAll
      models = users.models.slice()
      user.set 'group', null for user in models
    else if not @get('allows_multiple_memberships')
      @_unassignedUsers.increment group.usersCount()

    if not @get('allows_multiple_memberships') and (not users.loadedAll or not @_unassignedUsers.loadedAll)
      @_unassignedUsers.fetch()

  reassignUser: (user, newGroup) ->
    oldGroup = user.get('group')
    return if oldGroup is newGroup

    # if user is in _unassignedUsers and we allow multiple memberships,
    # don't actually move the user, move a copy instead
    if not oldGroup? and @get('allows_multiple_memberships')
      user = user.clone()
      user.once 'change:group', => @groupUsersFor(newGroup).addUser user

    user.save group: newGroup

  groupsCount: ->
    if @_groups?.loadedAll
      @_groups.length
    else
      @get('groups_count')

  groupUsersFor: (group) ->
    if group?
      group._users
    else
      @_unassignedUsers

  unassignedUsers: ->
    @_unassignedUsers = new UnassignedGroupUserCollection null,
      category: this
    @_unassignedUsers.on 'fetched:last', => @set('unassigned_users_count', @_unassignedUsers.length)
    @unassignedUsers = -> @_unassignedUsers
    @_unassignedUsers

  unassignedUsersCount: ->
    @get('unassigned_users_count')

  canAssignUnassignedMembers: ->
    @groupsCount() > 0 and
      not @get('allows_multiple_memberships') and
      @get('self_signup') isnt 'restricted' and
      @unassignedUsersCount() > 0

  canMessageUnassignedMembers: ->
    @unassignedUsersCount() > 0 and not ENV.IS_LARGE_ROSTER

  isLocked: ->
    # e.g. SIS groups, we shouldn't be able to edit them
    @get('role') is 'uncategorized'

  assignUnassignedMembers: (group_by_section) ->
    if group_by_section
      qs = "?group_by_section=1"
    else
      qs = ''
    $.ajaxJSON "/api/v1/group_categories/#{@id}/assign_unassigned_members#{qs}", 'POST', {}, @setUpProgress

  cloneGroupCategoryWithName: (name) ->
    $.ajaxJSON "/group_categories/#{@id}/clone_with_name", 'POST', {name: name}

  setUpProgress: (response) =>
    @set progress_url: response.url

  present: ->
    data = Backbone.Model::toJSON.call(this)
    data.progress = @progressModel.toJSON()
    data.groupCreationInProgress = data.progress.workflow_state is "queued" or
                                   data.progress.workflow_state is "running"
    data

  toJSON: ->
    _.omit(super, 'self_signup')

  @mixin DefaultUrlMixin

  sync: (method, model, options = {}) ->
    options.url = @urlFor(method)
    if method is 'create' and (model.get('split_groups') is '1' or model.get('split_groups') is '2')
      model.set('assign_async', true) # if we don't specify this, it will auto-assign on creation, not asyncronously
      group_by_section = (model.get('group_by_section') == '1')
      success = options.success ? ->
      options.success = (args) =>
        @progressStarting = true
        success(args)
        @assignUnassignedMembers(group_by_section)
    else if method is 'delete'
      if model.progressModel
        model.progressModel.onPoll = ->
    Backbone.sync method, model, options

  urlFor: (method) ->
    if method is 'create'
      @_defaultUrl()
    else
      "/api/v1/group_categories/#{@id}?includes[]=unassigned_users_count&includes[]=groups_count"
