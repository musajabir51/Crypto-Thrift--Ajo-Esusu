(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-member (err u101))
(define-constant err-already-member (err u102))
(define-constant err-insufficient-funds (err u103))
(define-constant err-not-active-cycle (err u104))
(define-constant err-cycle-in-progress (err u105))
(define-constant err-invalid-position (err u106))
(define-constant err-emergency-not-approved (err u107))
(define-constant err-no-emergency-request (err u108))
(define-constant err-already-requested (err u109))
(define-constant err-member-not-found (err u110))
(define-constant err-loan-not-found (err u111))
(define-constant err-insufficient-reputation (err u112))
(define-constant err-loan-already-active (err u113))
(define-constant err-repayment-too-early (err u114))
(define-constant err-invalid-repayment-amount (err u115))
(define-constant err-loan-already-repaid (err u116))
(define-constant err-max-loans-reached (err u117))
(define-constant err-insufficient-collateral (err u118))

(define-data-var cycle-id uint u0)
(define-data-var current-position uint u0)
(define-data-var contribution-amount uint u0)
(define-data-var cycle-active bool false)
(define-data-var total-members uint u0)
(define-data-var members-registry (list 100 principal) (list))

;; Loan system variables
(define-data-var next-loan-id uint u1)
(define-data-var loan-interest-rate uint u5) ;; 5% per cycle
(define-data-var min-reputation-for-loan uint u70)
(define-data-var max-loans-per-member uint u3)

(define-map members
    principal
    {
        position: uint,
        paid-current-cycle: bool,
        total-contributed: uint,
        total-received: uint,
        join-height: uint,
        emergency-requested: bool,
        on-time-payments: uint,
        late-payments: uint,
        missed-payments: uint,
        reputation-score: uint,
        cycles-participated: uint,
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

(define-map emergency-requests
    principal
    {
        request-height: uint,
        reason: (string-ascii 100),
        approved: bool,
        processed: bool,
    }
)

(define-map member-performance
    {
        member: principal,
        cycle: uint,
    }
    {
        payment-height: uint,
        payment-status: (string-ascii 20),
        days-late: uint,
    }
)

;; Loan system maps
(define-map loans
    uint
    {
        borrower: principal,
        amount: uint,
        interest-amount: uint,
        total-repayment: uint,
        amount-repaid: uint,
        request-height: uint,
        due-height: uint,
        status: (string-ascii 20), ;; "active", "repaid", "defaulted"
        collateral-amount: uint,
        reputation-at-request: uint,
    }
)

(define-map member-loans
    principal
    {
        active-loans: (list 10 uint),
        total-loans-taken: uint,
        total-repaid: uint,
        defaults: uint,
    }
)

(define-map loan-repayments
    {
        loan-id: uint,
        repayment-number: uint,
    }
    {
        amount: uint,
        repayment-height: uint,
        remaining-balance: uint,
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
        (var-set members-registry
            (unwrap!
                (as-max-len? (append (var-get members-registry) tx-sender) u100)
                err-invalid-position
            ))
        (ok (map-set members tx-sender {
            position: position,
            paid-current-cycle: false,
            total-contributed: u0,
            total-received: u0,
            join-height: burn-block-height,
            emergency-requested: false,
            on-time-payments: u0,
            late-payments: u0,
            missed-payments: u0,
            reputation-score: u100,
            cycles-participated: u0,
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
            (current-height burn-block-height)
            (cycle-start (get start-height cycle))
            (grace-period u20)
            (days-late (if (> current-height (+ cycle-start grace-period))
                (- current-height (+ cycle-start grace-period))
                u0
            ))
            (payment-status (if (is-eq days-late u0)
                "on-time"
                "late"
            ))
        )
        (asserts! (var-get cycle-active) err-not-active-cycle)
        (asserts! (not (get paid-current-cycle member)) err-already-member)
        (try! (stx-transfer? (var-get contribution-amount) tx-sender
            (as-contract tx-sender)
        ))
        (map-set member-performance {
            member: tx-sender,
            cycle: (var-get cycle-id),
        } {
            payment-height: current-height,
            payment-status: payment-status,
            days-late: days-late,
        })
        (let ((updated-member (if (is-eq payment-status "on-time")
                (merge member {
                    paid-current-cycle: true,
                    total-contributed: (+ (get total-contributed member)
                        (var-get contribution-amount)
                    ),
                    on-time-payments: (+ (get on-time-payments member) u1),
                    cycles-participated: (+ (get cycles-participated member) u1),
                })
                (merge member {
                    paid-current-cycle: true,
                    total-contributed: (+ (get total-contributed member)
                        (var-get contribution-amount)
                    ),
                    late-payments: (+ (get late-payments member) u1),
                    cycles-participated: (+ (get cycles-participated member) u1),
                })
            )))
            (map-set members tx-sender
                (merge updated-member { reputation-score: (calculate-reputation-score updated-member) })
            )
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
    (let ((member-list (var-get members-registry)))
        (fold check-member-position member-list none)
    )
)

(define-private (check-member-position
        (member principal)
        (current-match (optional principal))
    )
    (if (is-some current-match)
        current-match
        (let ((member-data (map-get? members member)))
            (match member-data
                member-info (if (is-eq (get position member-info) (var-get current-position))
                    (some member)
                    none
                )
                none
            )
        )
    )
)

(define-private (calculate-reputation-score (member-data {
    position: uint,
    paid-current-cycle: bool,
    total-contributed: uint,
    total-received: uint,
    join-height: uint,
    emergency-requested: bool,
    on-time-payments: uint,
    late-payments: uint,
    missed-payments: uint,
    reputation-score: uint,
    cycles-participated: uint,
}))
    (let (
            (total-payments (+ (get on-time-payments member-data) (get late-payments member-data)))
            (on-time-rate (if (> total-payments u0)
                (/ (* (get on-time-payments member-data) u100) total-payments)
                u100
            ))
            (participation-bonus (if (> (get cycles-participated member-data) u5)
                u10
                u0
            ))
            (penalty (if (> (get missed-payments member-data) u0)
                (* (get missed-payments member-data) u5)
                u0
            ))
        )
        (let ((base-score (+ on-time-rate participation-bonus)))
            (if (> base-score penalty)
                (- base-score penalty)
                u0
            )
        )
    )
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

(define-public (request-emergency-withdrawal (reason (string-ascii 100)))
    (let ((member (unwrap! (map-get? members tx-sender) err-not-member)))
        (asserts! (not (get emergency-requested member)) err-already-requested)
        (asserts! (is-none (map-get? emergency-requests tx-sender))
            err-already-requested
        )
        (map-set members tx-sender (merge member { emergency-requested: true }))
        (map-set emergency-requests tx-sender {
            request-height: burn-block-height,
            reason: reason,
            approved: false,
            processed: false,
        })
        (ok true)
    )
)

(define-public (approve-emergency-withdrawal (member-address principal))
    (let ((request (unwrap! (map-get? emergency-requests member-address)
            err-no-emergency-request
        )))
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (not (get processed request)) err-no-emergency-request)
        (map-set emergency-requests member-address
            (merge request { approved: true })
        )
        (ok true)
    )
)

(define-public (execute-emergency-withdrawal)
    (let (
            (request (unwrap! (map-get? emergency-requests tx-sender)
                err-no-emergency-request
            ))
            (member (unwrap! (map-get? members tx-sender) err-not-member))
            (cycle (unwrap! (map-get? cycles (var-get cycle-id)) err-not-active-cycle))
            (penalty-rate u10)
            (contributed (get total-contributed member))
            (penalty (/ (* contributed penalty-rate) u100))
            (withdrawal-amount (- contributed penalty))
        )
        (asserts! (get approved request) err-emergency-not-approved)
        (asserts! (not (get processed request)) err-no-emergency-request)
        (asserts! (> contributed u0) err-insufficient-funds)
        (try! (as-contract (stx-transfer? withdrawal-amount tx-sender tx-sender)))
        (map-set emergency-requests tx-sender (merge request { processed: true }))
        (map-delete members tx-sender)
        (ok withdrawal-amount)
    )
)

(define-private (calculate-emergency-withdrawal-amount
        (contributed uint)
        (penalty-rate uint)
    )
    (let ((penalty (/ (* contributed penalty-rate) u100)))
        (- contributed penalty)
    )
)

;; ====================== LOAN SYSTEM FUNCTIONS ======================

(define-public (request-loan (amount uint))
    (let (
            (member (unwrap! (map-get? members tx-sender) err-not-member))
            (reputation (get reputation-score member))
            (member-loan-data (default-to 
                { active-loans: (list), total-loans-taken: u0, total-repaid: u0, defaults: u0 }
                (map-get? member-loans tx-sender)
            ))
            (loan-id (var-get next-loan-id))
            (interest-amount (calculate-loan-interest amount))
            (total-repayment (+ amount interest-amount))
            (collateral-required (/ (* amount u20) u100)) ;; 20% collateral
            (available-collateral (get total-contributed member))
        )
        (asserts! (>= reputation (var-get min-reputation-for-loan)) err-insufficient-reputation)
        (asserts! (> amount u0) err-insufficient-funds)
        (asserts! (>= available-collateral collateral-required) err-insufficient-collateral)
        (asserts! (< (len (get active-loans member-loan-data)) (var-get max-loans-per-member)) err-max-loans-reached)
        
        ;; Check if member has any active loans
        (asserts! (is-eq (len (get active-loans member-loan-data)) u0) err-loan-already-active)
        
        ;; Create loan record
        (map-set loans loan-id {
            borrower: tx-sender,
            amount: amount,
            interest-amount: interest-amount,
            total-repayment: total-repayment,
            amount-repaid: u0,
            request-height: burn-block-height,
            due-height: (+ burn-block-height u1008), ;; Due in 1 week (1008 blocks)
            status: "active",
            collateral-amount: collateral-required,
            reputation-at-request: reputation,
        })
        
        ;; Update member loan tracking
        (map-set member-loans tx-sender (merge member-loan-data {
            active-loans: (unwrap! (as-max-len? (append (get active-loans member-loan-data) loan-id) u10) err-max-loans-reached),
            total-loans-taken: (+ (get total-loans-taken member-loan-data) u1),
        }))
        
        ;; Transfer funds to borrower
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        
        ;; Increment loan ID
        (var-set next-loan-id (+ loan-id u1))
        (ok loan-id)
    )
)

(define-public (make-repayment (loan-id uint) (amount uint))
    (let (
            (loan (unwrap! (map-get? loans loan-id) err-loan-not-found))
            (member-loan-data (unwrap! (map-get? member-loans tx-sender) err-not-member))
        )
        (asserts! (is-eq tx-sender (get borrower loan)) err-not-member)
        (asserts! (is-eq (get status loan) "active") err-loan-already-repaid)
        (asserts! (> amount u0) err-invalid-repayment-amount)
        
        (let (
                (remaining-debt (- (get total-repayment loan) (get amount-repaid loan)))
                (repayment-amount (if (> amount remaining-debt) remaining-debt amount))
                (new-amount-repaid (+ (get amount-repaid loan) repayment-amount))
                (loan-fully-repaid (>= new-amount-repaid (get total-repayment loan)))
                (repayment-number (+ (/ (get amount-repaid loan) (/ (get total-repayment loan) u10)) u1))
            )
            
            ;; Transfer repayment to contract
            (try! (stx-transfer? repayment-amount tx-sender (as-contract tx-sender)))
            
            ;; Record repayment
            (map-set loan-repayments {
                loan-id: loan-id,
                repayment-number: repayment-number,
            } {
                amount: repayment-amount,
                repayment-height: burn-block-height,
                remaining-balance: (- (get total-repayment loan) new-amount-repaid),
            })
            
            ;; Update loan status
            (map-set loans loan-id (merge loan {
                amount-repaid: new-amount-repaid,
                status: (if loan-fully-repaid "repaid" "active"),
            }))
            
            ;; If loan is fully repaid, clear active loans list (simplified approach)
            (if loan-fully-repaid
                (map-set member-loans tx-sender (merge member-loan-data {
                    active-loans: (list),
                    total-repaid: (+ (get total-repaid member-loan-data) u1),
                }))
                true
            )
            
            (ok repayment-amount)
        )
    )
)

(define-public (handle-loan-default (loan-id uint))
    (let (
            (loan (unwrap! (map-get? loans loan-id) err-loan-not-found))
            (member-loan-data (unwrap! (map-get? member-loans (get borrower loan)) err-not-member))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-eq (get status loan) "active") err-loan-already-repaid)
        (asserts! (> burn-block-height (get due-height loan)) err-repayment-too-early)
        
        ;; Mark loan as defaulted
        (map-set loans loan-id (merge loan { status: "defaulted" }))
        
        ;; Update member loan tracking (clear active loans for simplicity)
        (map-set member-loans (get borrower loan) (merge member-loan-data {
            active-loans: (list),
            defaults: (+ (get defaults member-loan-data) u1),
        }))
        
        ;; Apply reputation penalty to defaulting member
        (let ((member-data (unwrap! (map-get? members (get borrower loan)) err-not-member)))
            (map-set members (get borrower loan)
                (merge member-data {
                    reputation-score: (if (> (get reputation-score member-data) u20)
                        (- (get reputation-score member-data) u20)
                        u0
                    ),
                })
            )
        )
        
        (ok true)
    )
)

(define-private (calculate-loan-interest (principal-amount uint))
    (/ (* principal-amount (var-get loan-interest-rate)) u100)
)


(define-read-only (get-emergency-request (member principal))
    (map-get? emergency-requests member)
)

(define-read-only (get-member-reputation (member principal))
    (match (map-get? members member)
        member-data (ok {
            reputation-score: (get reputation-score member-data),
            on-time-payments: (get on-time-payments member-data),
            late-payments: (get late-payments member-data),
            missed-payments: (get missed-payments member-data),
            cycles-participated: (get cycles-participated member-data),
            payment-rate: (let ((total (+ (get on-time-payments member-data)
                    (get late-payments member-data)
                )))
                (if (> total u0)
                    (/ (* (get on-time-payments member-data) u100) total)
                    u0
                )
            ),
        })
        (err err-not-member)
    )
)

(define-read-only (get-member-performance
        (member principal)
        (cycle uint)
    )
    (map-get? member-performance {
        member: member,
        cycle: cycle,
    })
)

(define-read-only (get-top-performers (count uint))
    (let ((member-list (var-get members-registry)))
        (ok (map get-member-score member-list))
    )
)

(define-private (get-member-score (member principal))
    {
        member: member,
        score: (match (map-get? members member)
            member-data (get reputation-score member-data)
            u0
        ),
    }
)

;; ====================== LOAN SYSTEM READ-ONLY FUNCTIONS ======================

(define-read-only (get-loan-details (loan-id uint))
    (map-get? loans loan-id)
)

(define-read-only (get-member-loan-summary (member principal))
    (map-get? member-loans member)
)

(define-read-only (get-loan-repayment (loan-id uint) (repayment-number uint))
    (map-get? loan-repayments {
        loan-id: loan-id,
        repayment-number: repayment-number,
    })
)

(define-read-only (calculate-loan-eligibility (member principal))
    (match (map-get? members member)
        member-data (let (
                (reputation (get reputation-score member-data))
                (available-collateral (get total-contributed member-data))
                (member-loans-data (default-to 
                    { active-loans: (list), total-loans-taken: u0, total-repaid: u0, defaults: u0 }
                    (map-get? member-loans member)
                ))
                (active-loan-count (len (get active-loans member-loans-data)))
            )
            (ok {
                eligible: (and 
                    (>= reputation (var-get min-reputation-for-loan))
                    (< active-loan-count (var-get max-loans-per-member))
                    (> available-collateral u0)
                ),
                reputation-score: reputation,
                min-reputation-required: (var-get min-reputation-for-loan),
                active-loans: active-loan-count,
                max-loans-allowed: (var-get max-loans-per-member),
                available-collateral: available-collateral,
                max-loan-amount: (/ (* available-collateral u100) u20), ;; 5x collateral as max loan
            })
        )
        (err err-not-member)
    )
)

(define-read-only (get-loan-system-stats)
    (ok {
        total-loans-issued: (- (var-get next-loan-id) u1),
        current-interest-rate: (var-get loan-interest-rate),
        min-reputation-for-loan: (var-get min-reputation-for-loan),
        max-loans-per-member: (var-get max-loans-per-member),
    })
)

(define-read-only (check-loan-status (loan-id uint))
    (match (map-get? loans loan-id)
        loan (ok {
            status: (get status loan),
            amount-remaining: (- (get total-repayment loan) (get amount-repaid loan)),
            days-until-due: (if (> (get due-height loan) burn-block-height)
                (- (get due-height loan) burn-block-height)
                u0
            ),
            is-overdue: (> burn-block-height (get due-height loan)),
        })
        (err err-loan-not-found)
    )
)
