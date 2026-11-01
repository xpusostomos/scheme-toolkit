;;; (scheme-toolkit services battery) -- the battery (AstalBattery, plus the
;;; numbers Astal does not carry)
;;;
;;; TWO SOURCES, and the split between them is the point of this module.
;;;
;;; ASTAL for everything that CHANGES while you watch: charge, charging state,
;;; whether the device is present.  Those are live properties with `notify::'
;;; signals behind them, so a widget binds to them and updates itself.
;;;
;;; /sys/class/power_supply/BAT*/ for everything that DESCRIBES the cell: the
;;; energy it was designed to hold, its health, its cycle count.  Astal declares
;;; those properties and leaves them at zero -- measured: `capacity' 0.0 and
;;; `charge-cycles' 0 while UPower reports 77.29 and 388 -- and a zero that means
;;; "never assigned" is indistinguishable from a real zero, which is worse than
;;; an absence.
;;;
;;; WHY /sys AND NOT UPower's D-BUS.  UPower is where Omarchy reads them, and the
;;; values are identical (it reads these very files).  Reaching it from Scheme
;;; needs a GVariant argument built by hand, and G-Golf cannot do that yet:
;;; `g-variant-new-tuple' takes neither a vector nor a list of variants --
;;; "What array is this" -- so a D-Bus client belongs in the (scheme-toolkit
;;; dbus) module the plan already calls for, not improvised here.  A file read is
;;; the same data with no marshalling, no daemon and no subprocess.

(define-module (scheme-toolkit services battery)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit file)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 ftw)               ; `scandir'
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)

  #:export (battery
            battery-percentage battery-state battery-charging? battery-present?
            battery-on-battery? battery-charge-threshold? battery-state-value
            battery-sysfs-path battery-details
            battery-design-energy battery-full-energy battery-health battery-cycles
            battery-temperature battery-voltage battery-energy-rate
            battery-status-text))

(define (battery) (service-instance 'battery))

;;; ---------------------------------------------------------------------------
;;; Live, through Astal
;;; ---------------------------------------------------------------------------

(define (battery-percentage)
  "Charge as a number 0-1, or #f."
  (bind-obj (battery) "percentage" 'battery-percentage))

(define (battery-state)
  "The UPower device state, as a symbol: 'charging, 'discharging, 'fully-charged,
'pending-charge, 'unknown."
  (bind-obj (battery) "state" 'battery-state))

(define (battery-present?)
  "Whether there is a battery at all. A desktop answers #f, and a widget must
be absent rather than empty when it does."
  (bind-obj (battery) "is-present" 'battery-present?))

(define (device-ref prop)
  "A property of the battery device, read once."
  (let ((b (battery)))
    (and b (catch #t (lambda () (slot-ref b prop)) (lambda args #f)))))

(define (battery-charging?)
  "An ACCESSOR: is the battery taking charge?

AN ACCESSOR AND NOT A BOOLEAN, which the widgets depend on: every convenience
function in these service modules answers an accessor so it can be dropped
straight into a widget property, and a bare boolean here is `st-peek: not an
accessor #f` inside the bar -- at startup, taking the shell with it.

DERIVED FROM `state' AND NOT FROM ASTAL'S `charging', which is one of the
properties it leaves unset: measured on this machine `charging' reads #f while
`state' reads pending-charge, so the obvious property says a charging laptop is
not charging.

AND NOT WHILE A CHARGE LIMIT IS HOLDING, which is Omarchy's rule: a laptop parked
at 80% reports pending-charge, and a charging glyph there says the machine is
filling up when it has deliberately stopped."
  (create-computed
   (lambda ()
     (let ((state (battery-state))
           (pct (battery-percentage)))
       (and (or (eq? state 'charging) (eq? state 'pending-charge))
            ;; a limit, not a charge
            (not (or (eq? state 'pending-charge)
                     (and (eq? state 'fully-charged) (number? pct) (< pct 0.99))))
            #t)))
   'battery-charging?))

(define (battery-on-battery?)
  "Whether the machine is running off the battery rather than the adapter."
  (let ((b (battery)))
    (and b (catch #t (lambda () (slot-ref b 'power-supply) #t) (lambda args #f))
         (not (battery-charging?)))))

(define (battery-charge-threshold?)
  "Whether the machine is holding at a charge limit rather than charging.

THIS IS OMARCHY'S `chargeThresholdActive', minus its rate test.  A laptop stopped
at 80% reports pending-charge, and one that stopped after reaching 100% reports
fully-charged with a fraction below it -- both mean `plugged in, deliberately not
charging', and both should draw the DISCHARGING glyph rather than a charging one.
The third test in theirs -- a charge so slow it is really a threshold, from
`changeRate' and `timeToFull' -- is not reproduced: those are the two 64-bit
properties G-Golf cannot read (see `time-to-empty')."
  (let ((state (device-ref 'state))
        (pct (device-ref 'percentage)))
    (and (number? pct)
         (or (eq? state 'pending-charge)
             (and (eq? state 'fully-charged) (< pct 0.99))))))

;;; ---------------------------------------------------------------------------
;;; Describing the cell, through /sys
;;; ---------------------------------------------------------------------------

;; The kernel's power-supply class. `BAT0' here, `BAT1' or `CMB0' elsewhere, so
;; the directory is found rather than assumed.  A directory that will not open is
;; the ordinary case on a desktop, not a failure.
(define (power-supply-names)
  "The entries in /sys/class/power_supply, or '().

`scandir' AND NOT `readdir': Guile's `readdir' answers ONE entry per call, so
`(readdir dir)' is a string and treating it as a list is a `car' on a string --
which the compiler cannot see and only running it shows."
  (catch #t (lambda () (scandir "/sys/class/power_supply")) (lambda args '())))

(define (battery-sysfs-path)
  "The battery's directory under /sys/class/power_supply, or #f.

Found by name rather than assumed: the kernel calls it BAT0, BAT1, BATT or CMB0
depending on the machine, and a hard-coded BAT0 is a battery menu that silently
shows nothing on someone else's laptop.

/dev/null IS SKIPPED.  Every power supply has a `type' file, and only a battery's
says Battery; anything else in that directory is an adapter or a USB supply."
  (let loop ((names (power-supply-names)))
           (cond ((null? names) #f)
                 ((member (car names) '("." "..")) (loop (cdr names)))
                 (else
                  (let* ((base (string-append "/sys/class/power_supply/" (car names)))
                         (type (catch #t (lambda () (read-file (string-append base "/type")))
                                      (lambda args #f))))
                    (if (and type (string-prefix? "Battery" (string-trim-both type)))
                        base
                        (loop (cdr names))))))))

(define (sysfs-number file)
  "The number in FILE, or #f.  Absent files are the normal case: not every
battery reports temperature, and `cycle_count' is missing on plenty of them."
  (let ((path (battery-sysfs-path)))
    (and path
         (let ((text (catch #t (lambda () (read-file (string-append path "/" file)))
                               (lambda args #f))))
           (and text (string->number (string-trim-both text)))))))

(define (battery-design-energy)
  "The energy the battery was built to hold, in Wh, or #f.

The units are µWh in the file and Wh here, because that is the unit a person
reads and the unit UPower's own property is in (measured: 50500000 µWh, and
`EnergyFullDesign' 50.5)."
  (let ((micro (sysfs-number "energy_full_design")))
    (and micro (> micro 0) (/ micro 1000000))))

(define (battery-full-energy)
  "The energy it holds now when full, in Wh, or #f."
  (let ((micro (or (sysfs-number "energy_full") (sysfs-number "charge_full"))))
    (and micro (> micro 0) (/ micro 1000000))))

(define (battery-health)
  "Full-charge capacity as a fraction of the design capacity, or #f.

This is the number a battery menu is really for -- how much of the cell is left
after a few hundred cycles -- and it is the one neither Astal nor any single
UPower property states: it is the ratio of two.
The charge_* files are the same measurement in µAh on batteries that report
charge rather than energy."
  (let ((now (battery-full-energy))
        (design (battery-design-energy)))
    (and now design (> design 0) (min 1.0 (/ now design)))))

(define (battery-cycles)
  "Charge cycles, or #f when the battery does not report them (measured: 388)."
  (sysfs-number "cycle_count"))

(define (battery-temperature)
  "Temperature in degrees Celsius, or #f.  The file is in tenths."
  (let ((tenths (sysfs-number "temp")))
    (and tenths (/ tenths 10))))

(define (battery-voltage)
  "Voltage in volts, or #f.  The file is in µV."
  (let ((micro (sysfs-number "voltage_now")))
    (and micro (> micro 0) (/ micro 1000000))))

(define (battery-energy-rate)
  "Power draw in watts, or #f.  The file is in µW."
  (let ((micro (sysfs-number "power_now")))
    (and micro (/ micro 1000000))))

(define (battery-details)
  "Everything /sys can say about the battery, as an alist, or '().

READ ON DEMAND rather than on a timer: these numbers move over hours, and the
things that move over seconds -- charge and state -- come from Astal, which
signals.  A battery menu calls this when it opens."
  (if (not (battery-sysfs-path))
      '()
      `((path . ,(battery-sysfs-path))
        (design-energy . ,(battery-design-energy))
        (full-energy . ,(battery-full-energy))
        (health . ,(battery-health))
        (cycles . ,(battery-cycles))
        (temperature . ,(battery-temperature))
        (voltage . ,(battery-voltage))
        (energy-rate . ,(battery-energy-rate))
        (status . ,(catch #t (lambda () (string-trim-both
                                         (read-file (string-append (battery-sysfs-path) "/status"))))
                           (lambda args #f))))))

(define (battery-status-text)
  "The UPower state as a person reads it, for a menu line."
  (case (device-ref 'state)
    ((charging) "Charging")
    ((discharging) "Discharging")
    ((fully-charged) "Fully charged")
    ((pending-charge) "Not charging")
    ((empty) "Empty")
    (else "Unknown")))
