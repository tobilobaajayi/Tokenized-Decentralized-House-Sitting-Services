;; Mail Collection Contract
;; Handles package and correspondence management

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_NOT_FOUND (err u301))
(define-constant ERR_INVALID_INPUT (err u302))
(define-constant ERR_ALREADY_EXISTS (err u303))

;; Data Variables
(define-data-var mail-token-supply uint u1000000)
(define-data-var next-address-id uint u1)
(define-data-var next-delivery-id uint u1)

;; Data Maps
(define-map mail-addresses
  { address-id: uint }
  {
    owner: principal,
    collector: (optional principal),
    street-address: (string-ascii 200),
    forwarding-address: (optional (string-ascii 200)),
    active: bool,
    collection-frequency: uint,
    last-collected: uint
  }
)

(define-map deliveries
  { delivery-id: uint }
  {
    address-id: uint,
    collector: principal,
    delivery-type: (string-ascii 50),
    sender: (string-ascii 100),
    tracking-number: (optional (string-ascii 100)),
    received-date: uint,
    collected: bool,
    forwarded: bool,
    notes: (string-ascii 500)
  }
)

(define-map collection-records
  { address-id: uint, collection-id: uint }
  {
    collector: principal,
    collection-date: uint,
    item-count: uint,
    delivery-ids: (list 20 uint),
    verified: bool
  }
)

(define-map collector-balances
  { collector: principal }
  { balance: uint }
)

(define-map address-collection-count
  { address-id: uint }
  { count: uint }
)

;; Public Functions

;; Register a mail address for collection services
(define-public (register-address (street-address (string-ascii 200)) (collection-frequency uint))
  (let ((address-id (var-get next-address-id)))
    (asserts! (> (len street-address) u0) ERR_INVALID_INPUT)
    (asserts! (> collection-frequency u0) ERR_INVALID_INPUT)

    (map-set mail-addresses
      { address-id: address-id }
      {
        owner: tx-sender,
        collector: none,
        street-address: street-address,
        forwarding-address: none,
        active: false,
        collection-frequency: collection-frequency,
        last-collected: u0
      }
    )

    (var-set next-address-id (+ address-id u1))
    (ok address-id)
  )
)

;; Assign a mail collector to an address
(define-public (assign-collector (address-id uint) (collector principal))
  (let ((address (unwrap! (map-get? mail-addresses { address-id: address-id }) ERR_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get owner address)) ERR_UNAUTHORIZED)

    (map-set mail-addresses
      { address-id: address-id }
      (merge address { collector: (some collector), active: true })
    )

    (ok true)
  )
)

;; Set forwarding address
(define-public (set-forwarding-address (address-id uint) (forwarding-address (string-ascii 200)))
  (let ((address (unwrap! (map-get? mail-addresses { address-id: address-id }) ERR_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get owner address)) ERR_UNAUTHORIZED)
    (asserts! (> (len forwarding-address) u0) ERR_INVALID_INPUT)

    (map-set mail-addresses
      { address-id: address-id }
      (merge address { forwarding-address: (some forwarding-address) })
    )

    (ok true)
  )
)

;; Record a delivery
(define-public (record-delivery (address-id uint) (delivery-type (string-ascii 50)) (sender (string-ascii 100)) (tracking-number (optional (string-ascii 100))) (notes (string-ascii 500)))
  (let (
    (address (unwrap! (map-get? mail-addresses { address-id: address-id }) ERR_NOT_FOUND))
    (delivery-id (var-get next-delivery-id))
  )
    (asserts! (is-eq tx-sender (unwrap! (get collector address) ERR_UNAUTHORIZED)) ERR_UNAUTHORIZED)
    (asserts! (get active address) ERR_UNAUTHORIZED)
    (asserts! (> (len delivery-type) u0) ERR_INVALID_INPUT)
    (asserts! (> (len sender) u0) ERR_INVALID_INPUT)

    (map-set deliveries
      { delivery-id: delivery-id }
      {
        address-id: address-id,
        collector: tx-sender,
        delivery-type: delivery-type,
        sender: sender,
        tracking-number: tracking-number,
        received-date: block-height,
        collected: false,
        forwarded: false,
        notes: notes
      }
    )

    (var-set next-delivery-id (+ delivery-id u1))

    ;; Reward collector with mail tokens
    (let ((current-balance (default-to u0 (get balance (map-get? collector-balances { collector: tx-sender })))))
      (map-set collector-balances
        { collector: tx-sender }
        { balance: (+ current-balance u5) }
      )
    )

    (ok delivery-id)
  )
)

;; Collect mail and packages
(define-public (collect-mail (address-id uint) (delivery-ids (list 20 uint)))
  (let (
    (address (unwrap! (map-get? mail-addresses { address-id: address-id }) ERR_NOT_FOUND))
    (collection-count (default-to u0 (get count (map-get? address-collection-count { address-id: address-id }))))
    (new-collection-id (+ collection-count u1))
  )
    (asserts! (is-eq tx-sender (unwrap! (get collector address) ERR_UNAUTHORIZED)) ERR_UNAUTHORIZED)
    (asserts! (get active address) ERR_UNAUTHORIZED)
    (asserts! (> (len delivery-ids) u0) ERR_INVALID_INPUT)

    ;; Mark deliveries as collected
    (map mark-delivery-collected delivery-ids)

    (map-set collection-records
      { address-id: address-id, collection-id: new-collection-id }
      {
        collector: tx-sender,
        collection-date: block-height,
        item-count: (len delivery-ids),
        delivery-ids: delivery-ids,
        verified: false
      }
    )

    (map-set mail-addresses
      { address-id: address-id }
      (merge address { last-collected: block-height })
    )

    (map-set address-collection-count
      { address-id: address-id }
      { count: new-collection-id }
    )

    ;; Reward collector based on number of items
    (let ((current-balance (default-to u0 (get balance (map-get? collector-balances { collector: tx-sender })))))
      (map-set collector-balances
        { collector: tx-sender }
        { balance: (+ current-balance (* (len delivery-ids) u3)) }
      )
    )

    (ok new-collection-id)
  )
)

;; Forward mail to forwarding address
(define-public (forward-mail (delivery-id uint))
  (let (
    (delivery (unwrap! (map-get? deliveries { delivery-id: delivery-id }) ERR_NOT_FOUND))
    (address (unwrap! (map-get? mail-addresses { address-id: (get address-id delivery) }) ERR_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get collector delivery)) ERR_UNAUTHORIZED)
    (asserts! (is-some (get forwarding-address address)) ERR_INVALID_INPUT)
    (asserts! (not (get forwarded delivery)) ERR_ALREADY_EXISTS)

    (map-set deliveries
      { delivery-id: delivery-id }
      (merge delivery { forwarded: true })
    )

    ;; Reward for forwarding service
    (let ((current-balance (default-to u0 (get balance (map-get? collector-balances { collector: tx-sender })))))
      (map-set collector-balances
        { collector: tx-sender }
        { balance: (+ current-balance u8) }
      )
    )

    (ok true)
  )
)

;; Verify a collection (owner only)
(define-public (verify-collection (address-id uint) (collection-id uint))
  (let (
    (collection (unwrap! (map-get? collection-records { address-id: address-id, collection-id: collection-id }) ERR_NOT_FOUND))
    (address (unwrap! (map-get? mail-addresses { address-id: address-id }) ERR_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get owner address)) ERR_UNAUTHORIZED)

    (map-set collection-records
      { address-id: address-id, collection-id: collection-id }
      (merge collection { verified: true })
    )

    ;; Additional reward for verified collection
    (let ((collector (get collector collection)))
      (let ((current-balance (default-to u0 (get balance (map-get? collector-balances { collector: collector })))))
        (map-set collector-balances
          { collector: collector }
          { balance: (+ current-balance u10) }
        )
      )
    )

    (ok true)
  )
)

;; Private Functions

(define-private (mark-delivery-collected (delivery-id uint))
  (match (map-get? deliveries { delivery-id: delivery-id })
    delivery (map-set deliveries
               { delivery-id: delivery-id }
               (merge delivery { collected: true }))
    false
  )
)

;; Read-only functions

(define-read-only (get-mail-address (address-id uint))
  (map-get? mail-addresses { address-id: address-id })
)

(define-read-only (get-delivery (delivery-id uint))
  (map-get? deliveries { delivery-id: delivery-id })
)

(define-read-only (get-collection-record (address-id uint) (collection-id uint))
  (map-get? collection-records { address-id: address-id, collection-id: collection-id })
)

(define-read-only (get-collector-balance (collector principal))
  (default-to u0 (get balance (map-get? collector-balances { collector: collector })))
)

(define-read-only (get-next-address-id)
  (var-get next-address-id)
)

(define-read-only (get-next-delivery-id)
  (var-get next-delivery-id)
)

(define-read-only (get-address-collection-count (address-id uint))
  (default-to u0 (get count (map-get? address-collection-count { address-id: address-id })))
)
