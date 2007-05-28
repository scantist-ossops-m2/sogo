var SOGoDragHandlesInterface = {
  dhType: null,
  origX: -1,
  origLeft: -1,
  origRight: -1,
  origY: -1, 
  origUpper: -1,
  origLower: -1,
  delta: -1,
  leftBlock: null,
  rightBlock: null,
  upperBlock: null,
  lowerBlock: null,
  startHandleDraggingBinded: null,
  stopHandleDraggingBinded: null,
  moveBinded: null,
  bind: function () {
    this.startHandleDraggingBound = this.startHandleDragging.bindAsEventListener(this);
    Event.observe(this, "mousedown", this.startHandleDraggingBound, false);
  },
  _determineType: function () {
    if (this.leftBlock && this.rightBlock)
      this.dhType = 'horizontal';
    else if (this.upperBlock && this.lowerBlock)
      this.dhType = 'vertical';
  },
  startHandleDragging: function (event) {
    if (!this.dhType)
      this._determineType();
    var targ;
    if (!event)
      var event = window.event;
    if (event.target)
      targ = event.target
    else if (event.srcElement)
      targ = event.srcElement
    if (targ.nodeType == 1) {
      if (this.dhType == 'horizontal') {
        this.origX = this.offsetLeft;
        this.origLeft = this.leftBlock.offsetWidth;
        delta = 0;
        this.origRight = this.rightBlock.offsetLeft - 5;
        document.body.style.cursor = "e-resize";
      } else if (this.dhType == 'vertical') {
        this.origY = this.offsetTop;
        this.origUpper = this.upperBlock.offsetHeight;
        delta = event.clientY - this.offsetTop - 5;
        this.origLower = this.lowerBlock.offsetTop - 5;
        document.body.style.cursor = "n-resize";
      }
      this.stopHandleDraggingBound = this.stopHandleDragging.bindAsEventListener(this);
      Event.observe(document.body, "mouseup", this.stopHandleDraggingBound, true);
      this.moveBound = this.move.bindAsEventListener(this);
      Event.observe(document.body, "mousemove", this.moveBound, true);
      this.move(event);
      event.cancelBubble = true;
    }

    return false;
  },
  stopHandleDragging: function (event) {
    if (!this.dhType)
      this._determineType();
    if (this.dhType == 'horizontal') {
      var deltaX
        = Math.floor(event.clientX - this.origX - (this.offsetWidth / 2));
      this.rightBlock.style.left = (this.origRight + deltaX) + 'px';
      this.leftBlock.style.width = (this.origLeft + deltaX) + 'px';
    } else if (this.dhType == 'vertical') {
      var deltaY
        = Math.floor(event.clientY - this.origY - (this.offsetHeight / 2));
      this.lowerBlock.style.top = (this.origLower + deltaY - delta) + 'px';
      this.upperBlock.style.height = (this.origUpper + deltaY - delta) + 'px';
    }
 
    Event.stopObserving(document.body, "mouseup", this.stopHandleDraggingBound, true);
    Event.stopObserving(document.body, "mousemove", this.moveBound, true);
    
    document.body.setAttribute('style', '');
    
    this.move(event);
    event.cancelBubble = true;

    return false;
  },
  move: function (event) {
    if (!this.dhType)
      this._determineType();
    if (this.dhType == 'horizontal') {
      var width = this.offsetWidth;
      var hX = event.clientX;
      if (hX > -1) {
        var newLeft = Math.floor(hX - (width / 2));
        this.style.left = newLeft + 'px';
        event.cancelBubble = true;
      
        return false;
      }
    } else if (this.dhType == 'vertical') {
      var height = this.offsetHeight;
      var hY = event.clientY;
      if (hY > -1) {
        var newTop = Math.floor(hY - (height / 2))  - delta;
        this.style.top = newTop + 'px';
        event.cancelBubble = true;

        return false;
      }
    }
  },
  doubleClick: function (event) {
    if (!this.dhType)
      this._determineType();
    if (this.dhType == 'horizontal') {
      var lLeft = this.leftBlock.offsetLeft;
    
      if (this.offsetLeft > lLeft) {
        var leftdelta = this.rightBlock.offsetLeft - this.offsetLeft;

        this.style.left = lLeft + 'px';
        this.leftBlock.style.width = '0px';
        this.rightBlock.style.left = (lLeft + leftdelta) + 'px';
      }
    } else if (this.dhType == 'vertical') {
      var uTop = this.upperBlock.offsetTop;

      if (this.offsetTop > uTop) {
        var topdelta = this.lowerBlock.offsetTop - this.offsetTop;
      
        this.style.top = uTop + 'px';
        this.upperBlock.style.width = '0px';
        this.lowerBlock.style.top = (uTop + topdelta) + 'px';
      }
    }
  }

};
