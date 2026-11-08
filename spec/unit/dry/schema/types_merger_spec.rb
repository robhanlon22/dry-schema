# frozen_string_literal: true

require "dry/types"
require "dry/logic"

require "dry/schema/types_merger"

RSpec.describe Dry::Schema::TypesMerger do
  subject(:types_merger) { Dry::Schema::TypesMerger.new }

  describe "#call" do
    context Dry::Logic::Operations::Or do
      it "applies all when keys collide" do
        expect(
          types_merger
            .call(
              Dry::Logic::Operations::Or,
              {foo: Types::Integer, bar: Types::Integer},
              {foo: Types::String}
            )
            .transform_values(&:to_ast)
        ).to eq(
          {
            foo: [
              :sum,
              [
                [
                  :constrained,
                  [
                    [:nominal, [Integer, {}, {}]],
                    [
                      :predicate,
                      [:type?, [[:type, Integer], [:input, Undefined]]]
                    ]
                  ]
                ],
                [
                  :constrained,
                  [
                    [:nominal, [String, {}, {}]],
                    [
                      :predicate,
                      [:type?, [[:type, String], [:input, Undefined]]]
                    ]
                  ]
                ],
                {}
              ]
            ],
            bar: [
              :constrained,
              [
                [:nominal, [Integer, {}, {}]],
                [:predicate, [:type?, [[:type, Integer], [:input, Undefined]]]]
              ]
            ]
          }
        )
      end
    end

    [
      [Dry::Logic::Operations::And, :and],
      [Dry::Logic::Operations::Implication, :implication]
    ].each do |op_class, op_node_type|
      context op_class do
        it "applies all when keys collide" do
          expect(
            types_merger
              .call(
                op_class,
                {foo: Types::Integer.constrained(gteq: 1)},
                {foo: Types::Integer.constrained(lteq: 3)}
              )
              .transform_values(&:to_ast)
          ).to eq(
            {
              foo: [
                :constrained,
                [
                  [:nominal, [Integer, {}, {}]],
                  [
                    op_node_type,
                    [
                      [
                        :and,
                        [
                          [
                            :predicate,
                            [:type?, [[:type, Integer], [:input, Undefined]]]
                          ],
                          [
                            :predicate,
                            [:gteq?, [[:num, 1], [:input, Undefined]]]
                          ]
                        ]
                      ],
                      [
                        :and,
                        [
                          [
                            :predicate,
                            [:type?, [[:type, Integer], [:input, Undefined]]]
                          ],
                          [
                            :predicate,
                            [:lteq?, [[:num, 3], [:input, Undefined]]]
                          ]
                        ]
                      ]
                    ]
                  ]
                ]
              ]
            }
          )
        end

        it "retains the strict hash rule and inherited key types in a merged schema" do
          left = Types::Hash.schema(bar: Types::Integer)
          right = Types::Hash.schema(baz: Types::Integer.optional, note?: Types::String)
          merged = types_merger.call(op_class, {foo: left}, {foo: right.optional}).fetch(:foo)

          expect(merged.type.rule).to eq(Types::Hash.rule)
          expect(merged.keys.map(&:type)).to eq(left.keys + right.keys)
          expect(merged.call(bar: 1, baz: nil)).to eq(bar: 1, baz: nil)
        end

        it "retains the right-hand hash constructor when the constructors differ" do
          left = Types::Params::Hash.schema(x: Types::Params::Integer).constructor { |value| value.merge(x: 7) }
          right = Types::Params::Hash.schema(x: Types::Params::Integer)
          merged = types_merger.call(op_class, {options: left}, {options: right}).fetch(:options)

          expect(merged.call(x: "3")).to eq(x: 3)
        end

        it "uses the rhs if the lhs is an Any" do
          expect(
            types_merger
              .call(op_class, {foo: Types::Any}, {foo: Types::Integer})
              .transform_values(&:to_ast)
          ).to eq(
            {
              foo: [
                :constrained,
                [
                  [:nominal, [Integer, {}, {}]],
                  [
                    :predicate,
                    [:type?, [[:type, Integer], [:input, Undefined]]]
                  ]
                ]
              ]
            }
          )
        end

        it "uses the rhs if the rhs is a subclass of lhs" do
          expect(
            types_merger
              .call(
                op_class,
                {foo: Types::Hash},
                {foo: Types::Hash.schema(bar: Types::Integer)}
              )
              .transform_values(&:to_ast)
          ).to eq(
            {
              foo: [
                :constrained,
                [
                  [
                    :schema,
                    [
                      [
                        [
                          :key,
                          [
                            :bar,
                            true,
                            [
                              :constrained,
                              [
                                [:nominal, [Integer, {}, {}]],
                                [
                                  :predicate,
                                  [
                                    :type?,
                                    [[:type, Integer], [:input, Undefined]]
                                  ]
                                ]
                              ]
                            ]
                          ]
                        ]
                      ],
                      {},
                      {}
                    ]
                  ],
                  [
                    op_node_type,
                    [
                      [
                        :predicate,
                        [:type?, [[:type, Hash], [:input, Undefined]]]
                      ],
                      [
                        :predicate,
                        [:type?, [[:type, Hash], [:input, Undefined]]]
                      ]
                    ]
                  ]
                ]
              ]
            }
          )
        end

        it "uses the lhs if the rhs is an Any" do
          expect(
            types_merger
              .call(op_class, {foo: Types::Integer}, {foo: Types::Any})
              .transform_values(&:to_ast)
          ).to eq(
            {
              foo: [
                :constrained,
                [
                  [:nominal, [Integer, {}, {}]],
                  [
                    :predicate,
                    [:type?, [[:type, Integer], [:input, Undefined]]]
                  ]
                ]
              ]
            }
          )
        end

        it "uses the lhs if the lhs is a subclass of rhs" do
          expect(
            types_merger
              .call(
                op_class,
                {foo: Types::Hash.schema(bar: Types::Integer)},
                {foo: Types::Hash}
              )
              .transform_values(&:to_ast)
          ).to eq(
            {
              foo: [
                :constrained,
                [
                  [
                    :schema,
                    [
                      [
                        [
                          :key,
                          [
                            :bar,
                            true,
                            [
                              :constrained,
                              [
                                [:nominal, [Integer, {}, {}]],
                                [
                                  :predicate,
                                  [
                                    :type?,
                                    [[:type, Integer], [:input, Undefined]]
                                  ]
                                ]
                              ]
                            ]
                          ]
                        ]
                      ],
                      {},
                      {}
                    ]
                  ],
                  [
                    op_node_type,
                    [
                      [
                        :predicate,
                        [:type?, [[:type, Hash], [:input, Undefined]]]
                      ],
                      [
                        :predicate,
                        [:type?, [[:type, Hash], [:input, Undefined]]]
                      ]
                    ]
                  ]
                ]
              ]
            }
          )
        end
      end
    end
  end
end
