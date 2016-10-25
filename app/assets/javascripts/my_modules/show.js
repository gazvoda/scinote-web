(function() {
  'use strict';

  function applyDeleteWidgetCallBack() {
    $("[data-action='delete-widget']")
    .on('confirm:complete', function(e, answer) {
      if (answer) {
        animateLoading();
      }
    });
  }

  function applyMoveWidgetCallBack() {
    $("[data-action='move-widget']")
    .on('ajax:success', function(e, data) {
      var $widget = $(this).closest('.widget'),
        $widgetDown, $widgetUp;
      switch (data.move_direction) {
        case 'up':
          $widgetDown = $widget.prev('.widget');
          $widgetUp = $widget;
          break;
        case 'down':
          $widgetDown = $widget;
          $widgetUp = $widget.next('.widget');
          break;
        default:
      }

      // Switch position of top and bottom widgets
      if (!_.isUndefined($widgetDown) && !_.isUndefined($widgetUp)) {
        $widgetDown.insertAfter($widgetUp);
        $('html, body').animate({
          scrollTop: $widget.offset().top - window.innerHeight / 2});
      }
    });
  }

  function applyCollapseLinkCallBack() {
    $('.widget-panel-collapse-link')
      .on('ajax:success', function() {
        var collapseIcon = $(this).find('.collapse-widget-icon'),
          collapsed = $(this).hasClass('collapsed');
        // Toggle collapse button
        collapseIcon.toggleClass('glyphicon-collapse-up', !collapsed);
        collapseIcon.toggleClass('glyphicon-collapse-down', collapsed);
      });
  }

  function initCallBacks() {
    applyDeleteWidgetCallBack();
    applyMoveWidgetCallBack();
    applyCollapseLinkCallBack();
  }

  function toggleButtons(show) {
    if (show) {
      // Show 'no widgets' label if no widgets are present
      if ($('.widget').length) {
        $("[data-role='no-widgets-text']").hide();
      } else {
        $("[data-role='no-widgets-text']").show();
      }
    } else {
      // Hide 'no widgets' label if no widgets are present
      $("[data-role='no-widgets-text']").hide();
    }
  }

  function expandAllWidgets() {
    $('.widget .panel-collapse').collapse('show');
    $(document).find('span.collapse-widget-icon').each(function() {
      $(this).addClass('glyphicon-collapse-up');
      $(this).removeClass('glyphicon-collapse-down');
    });
  }

  $(document).ready(function() {
    initCallBacks();
    toggleButtons(true);
    expandAllWidgets();
  });
})();