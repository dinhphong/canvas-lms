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

import Backbone from '@canvas/backbone'
import ValidatedMixin from './ValidatedMixin'
import $ from 'jquery'
import _ from 'underscore'
import {useScope as useI18nScope} from '@canvas/i18n'
import '@canvas/util/toJSON'
import '@canvas/jquery/jquery.disableWhileLoading'
import '../../jquery/jquery.instructure_forms'
import {send} from '@canvas/rce/RceCommandShim'
import {shimGetterShorthand} from '@canvas/util/legacyCoffeesScriptHelpers'
import sanitizeData from '../../sanitizeData'

I18n = useI18nScope('errors')

##
# Sets model data from a form, saves it, and displays errors returned in a
# failed request.
#
# @event submit
#
# @event fail
#   @signature `(errors, jqXHR, status, statusText)`
#   @param errors - the validation errors, each error has the form $input
#                   and the $errorBox attached to it for easy access
#
# @event success
#   @signature `(response, status, jqXHR)`
export default class ValidatedFormView extends Backbone.View

  @mixin ValidatedMixin

  tagName: 'form'

  className: 'validated-form-view'

  events:
    submit: 'submit'

  ##
  # Default options to pass when saving the model.
  saveOpts:
    # wait for server success response before updating model attributes locally
    wait: true

  ##
  # Default options to pass to disableWhileLoading when submitting
  disableWhileLoadingOpts: {}

  ##
  # Sets the model data from the form and saves it. Called when the form
  # submits, or can be called programatically.
  # set @saveOpts in your view to to pass opts to Backbone.sync (like multipart: true if you have
  # a file attachment).  if you want the form not to be re-enabled after save success (because you
  # are navigating to a new page, set dontRenableAfterSaveSuccess to true on your view)
  #
  # NOTE: If you are uploading a file attachment, be careful! our
  # syncWithMultipart extension doesn't call toJSON on your model!
  #
  # @api public
  # @returns jqXHR
  submit: (event, sendFunc = send) ->
    event?.preventDefault()
    @hideErrors()


    rceInputs = @$el.find('textarea[data-rich_text]').toArray()

    okayToContinue = true
    if rceInputs.length > 0
      okayToContinue = rceInputs.map((rce) => sendFunc($(rce), 'checkReadyToGetCode', window.confirm)).every((value) => value)

    if !okayToContinue
      return

    data = @getFormData()
    errors = @validateBeforeSave data, {}

    if _.keys(errors).length == 0
      disablingDfd = new $.Deferred()
      saveDfd = @saveFormData(data)
      saveDfd.then(@onSaveSuccess.bind(this), @onSaveFail.bind(this))
      saveDfd.fail =>
        disablingDfd.reject()
        @setFocusAfterError() if @setFocusAfterError

      unless @dontRenableAfterSaveSuccess
        saveDfd.done -> disablingDfd.resolve()

      @$el.disableWhileLoading disablingDfd, @disableWhileLoadingOpts

      # Indicate to the RCE that the page is closing.
      if rceInputs.length > 0
        rceInputs.forEach((rce) => sendFunc($(rce), "RCEClosed"))

      @trigger 'submit'
      saveDfd
    else
      # focus on the first element with an error for accessibility
      dateOverrideErrors = _.map($('[data-error-type]'), (element) =>
        $(element).attr('data-error-type')
      )
      assignmentFieldErrors = _.chain(_.keys(errors))
                              .reject((err) -> _.includes(dateOverrideErrors, err))
                              .value()
      first_error = assignmentFieldErrors[0] || dateOverrideErrors[0]
      @findField(first_error).focus()
      # short timeout to ensure alerts are properly read after focus change.
      window.setTimeout((=>
        @showErrors errors
        null
      ), 50)

  cancel: ->
    rceInputs = @$el.find('textarea[data-rich_text]').toArray()
    rceInputs.forEach((rce) => send($(rce), "RCEClosed"))

  ##
  # Converts the form to an object. Override this if the form's input names
  # don't match the model/API fields
  getFormData: ->
    sanitizeData(@$el.toJSON())

  ##
  # Saves data from the form using the model.
  # Override to provide customized saving behavior.
  saveFormData: (data=null) ->
    model = @model
    data ||= @getFormData()
    saveOpts = @saveOpts
    model.save(data, saveOpts)

  ##
  # Performs validation on the form, using the validateFormData method, and
  # shows the errors using showErrors.
  #
  # Override validateFormData or showErrors to change their respective behaviors.
  #
  # @api public
  # @returns true if there were no validation errors, otherwise false
  validate: (opts={}) ->
    opts ||= {}
    data = opts['data'] || @getFormData()
    errors = @validateFormData data, {}

    @hideErrors()
    @showErrors(errors)
    errors.length == 0

  ##
  # Validates provided form data, returning any errors found.
  # Override to provide customized validation behavior.
  #
  # @returns errors (see parseErrorResponse for the errors format)
  validateFormData: (data) ->
    {}

  ##
  # Validates provided form data just before saving, returning any errors
  # found. By default it delegates to @validateFormData to perform validation,
  # but allows for alternative save-oriented validation to be performed.
  # Override to provide customized pre-save validation behavior.
  #
  # @returns errors (see parseErrorResponse for the errors format)
  validateBeforeSave: (data) ->
    @validateFormData(data)

  ##
  # Hides all errors previously shown in the UI.
  # Override to match the way showErrors displays the errors.
  hideErrors: ->
    @$el.hideErrors()

  onSaveSuccess: (xhr) =>
    @trigger 'success', xhr, arguments...

  onSaveFail: (xhr) =>
    errors = @parseErrorResponse xhr
    errors ||= {}
    @showErrors errors
    @trigger 'fail', errors, arguments...

  ##
  # Parses the response body into an error object `@showErrors` understands.
  # Override for API end-points that don't follow convention, needs to return
  # something that looks like this:
  #
  #   {
  #     <field1>: [errors],
  #     <field2>: [errors]
  #   }
  #
  # For example:
  #
  #   {
  #     first_name: [
  #       {
  #         type: 'required'
  #         message: 'First name is required'
  #       },
  #       {
  #         type: 'no_numbers',
  #         message: "First name can't contain numbers"
  #       }
  #     ]
  #   }
  parseErrorResponse: (response) ->
    if response.status is 422
      {authenticity_token: "invalid"}
    else
      try
        $.parseJSON(response.responseText).errors
      catch error
        {}

  translations: shimGetterShorthand {},
    required: -> I18n.t "required", "Required"
    blank: -> I18n.t "blank", "Required"
    unsaved: -> I18n.t "unsaved_changes", "You have unsaved changes."

  ##
  # Errors are displayed relative to the field to which they belong. If
  # the key of the error in the response doesn't match the name attribute
  # of the form input element, configure a selector here.
  #
  # For example, given a form field like this:
  #
  #   <input name="user[first_name]">
  #
  # and an error response like this:
  #
  #   {errors: { first_name: {...} }}
  #
  # you would do this:
  #
  #   fieldSelectors:
  #     first_name: '[name=user[first_name]]'
  fieldSelectors: null

  findField: (field) ->
    selector = @fieldSelectors?[field] or "[name='#{field}']"
    $el = @$(selector)
    if $el.length == 0 # 3rd fallback in case prior selectors find no elements
      $el = @$("[data-error-type='#{field}']")
    if $el.data('rich_text')
      $el = @findSiblingTinymce($el)
    if $el.length > 1 # e.g. hidden input + checkbox, show it by the checkbox
      $el = $el.not('[type=hidden]')
    $el

  castJSON: (obj) ->
    return obj unless _.isObject(obj)
    return obj.toJSON() if obj.toJSON?
    clone = _.clone(obj)
    _.each clone, (val, key) => clone[key] = @castJSON(val)
    clone

  original: null
  watchUnload: =>
    @original = @castJSON(@getFormData())
    @unwatchUnload()
    $(window).on 'beforeunload', @checkUnload

  unwatchUnload: ->
    $(window).off 'beforeunload', @checkUnload

  checkUnload: =>
    current = @castJSON(@getFormData())
    @translations.unsaved unless _.isEqual(@original, current)
