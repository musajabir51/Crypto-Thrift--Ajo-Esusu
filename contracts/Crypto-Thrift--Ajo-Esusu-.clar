(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-member (err u101))
(define-constant err-already-member (err u102))
(define-constant err-insufficient-funds (err u103))
(define-constant err-not-active-cycle (err u104))
(define-constant err-cycle-in-progress (err u105))
(define-constant err-invalid-position (err u106))

(define-data-var cycle-id uint u0)
(define-data-var current-position uint u0)
(define-data-var contribution-amount uint u0)
(define-data-var cycle-active bool false)
(define-data-var total-members uint u0)

(define-map members
    principal
    {
        position: uint,
        paid-current-cycle: bool,
        total-contributed: uint,
        total-received: uint,
        join-height: uint,
    }
)

(define-map cycles
    uint
    {
        start-height: uint,
        end-height: uint,
        total-amount: uint,
        members-count: uint,
        completed: bool,
    }
)

(define-public (initialize-thrift
        (amount uint)
        (member-count uint)
    )
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (> amount u0) err-insufficient-funds)
        (asserts! (> member-count u1) err-invalid-position)
        (var-set contribution-amount amount)
        (var-set total-members member-count)
        (ok true)
    )
)

(define-public (join-thrift (position uint))
    (let ((current-cycle (var-get cycle-id)))
        (asserts! (not (var-get cycle-active)) err-cycle-in-progress)
        (asserts! (<= position (var-get total-members)) err-invalid-position)
        (asserts! (is-none (map-get? members tx-sender)) err-already-member)
        (ok (map-set members tx-sender {
            position: position,
            paid-current-cycle: false,
            total-contributed: u0,
            total-received: u0,
            join-height: u0,
        }))
    )
)

(define-public (start-cycle)
    (let ((current-height u0))
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (not (var-get cycle-active)) err-cycle-in-progress)
        (var-set cycle-active true)
        (var-set current-position u1)
        (map-set cycles (+ (var-get cycle-id) u1) {
            start-height: current-height,
            end-height: (+ current-height u144),
            total-amount: u0,
            members-count: (var-get total-members),
            completed: false,
        })
        (var-set cycle-id (+ (var-get cycle-id) u1))
        (ok true)
    )
)

(define-public (contribute)
    (let (
            (cycle (unwrap! (map-get? cycles (var-get cycle-id)) err-not-active-cycle))
            (member (unwrap! (map-get? members tx-sender) err-not-member))
        )
        (asserts! (var-get cycle-active) err-not-active-cycle)
        (asserts! (not (get paid-current-cycle member)) err-already-member)
        (try! (stx-transfer? (var-get contribution-amount) tx-sender
            (as-contract tx-sender)
        ))
        (map-set members tx-sender
            (merge member {
                paid-current-cycle: true,
                total-contributed: (+ (get total-contributed member) (var-get contribution-amount)),
            })
        )
        (map-set cycles (var-get cycle-id)
            (merge cycle { total-amount: (+ (get total-amount cycle) (var-get contribution-amount)) })
        )
        (ok true)
    )
)

(define-public (distribute-funds)
    (let (
            (cycle (unwrap! (map-get? cycles (var-get cycle-id)) err-not-active-cycle))
            (current-pos (var-get current-position))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (var-get cycle-active) err-not-active-cycle)
        (let ((recipient (unwrap! (find-recipient-by-position current-pos)
                err-invalid-position
            )))
            (try! (as-contract (stx-transfer? (get total-amount cycle) tx-sender recipient)))
            (let ((member-data (unwrap! (map-get? members recipient) err-not-member)))
                (map-set members recipient
                    (merge member-data { total-received: (+ (get total-received member-data) (get total-amount cycle)) })
                )
            )
        )
        (if (is-eq current-pos (var-get total-members))
            (begin
                (var-set cycle-active false)
                (map-set cycles (var-get cycle-id)
                    (merge cycle { completed: true })
                )
            )
            (var-set current-position (+ current-pos u1))
        )
        (ok true)
    )
)

(define-private (find-recipient-by-position (pos uint))
    (some tx-sender)
)

(define-read-only (get-member-info (member principal))
    (map-get? members member)
)

(define-read-only (get-cycle-info (cycle-number uint))
    (map-get? cycles cycle-number)
)

(define-read-only (get-current-cycle)
    (var-get cycle-id)
)
